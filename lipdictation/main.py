"""Lip dictation: hold a key, silently mouth the words, release, and the text is pasted.

  lip-dictation                 run the dictation loop (from macOS Terminal)
  lip-dictation file VIDEO      lip-read a video file, to test without the camera
"""
import argparse
import os
import sys
import threading
import time
from collections import deque
from pathlib import Path

os.environ.setdefault("GLOG_minloglevel", "2")       # quiet MediaPipe
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "models"
TAIL = 0.4          # keep filming after release: the model needs the frames after the last word
MIN_SECONDS = 0.6   # shorter holds are taken as accidental taps


def load_reader(args):
    from .vsr import LipReader
    t = time.perf_counter()
    reader = LipReader(MODELS, beam_size=args.beam)
    print(f"Lip reader loaded in {time.perf_counter() - t:.1f}s"
          f" ({'Apple GPU' if reader.gpu else 'CPU'} encoder)")
    return reader


class Dictation:
    def __init__(self, args, reader, cleaner):
        from . import macos
        from .camera import Camera
        self.macos = macos
        self.args = args
        self.reader = reader
        self.cleaner = cleaner
        self.camera = Camera(args.camera, MODELS / "face_landmarker.task")
        self.recent = deque(maxlen=5)
        self.busy = threading.Lock()      # one dictation at a time
        self.pressed_at = None
        self.cancelled = False

    # Called from the key watcher. Work goes to threads so the event tap never stalls.
    def on_down(self):
        if self.busy.locked():
            return
        self.cancelled = False
        self.pressed_at = time.monotonic()
        threading.Thread(target=self._start, daemon=True).start()

    def on_up(self):
        if self.pressed_at is None:
            return
        held = time.monotonic() - self.pressed_at
        self.pressed_at = None
        threading.Thread(target=self._finish, args=(held,), daemon=True).start()

    def on_cancel(self):
        if self.pressed_at is not None:
            self.cancelled = True
            self.pressed_at = None
            self.camera.cancel()
            self.macos.sound("Funk")
            print("  cancelled")

    def _start(self):
        try:
            self.camera.start()
        except RuntimeError as e:
            print(e)
            return
        if self.camera.first_frame.wait(2.0):
            self.macos.sound("Tink")
            print("● listening…", flush=True)
        else:
            print("  no camera frames; is another app using the camera?")

    def _finish(self, held):
        with self.busy:
            time.sleep(TAIL)
            frames, anchors, stamps = self.camera.stop()
            if self.cancelled:
                return
            if held < MIN_SECONDS or len(frames) < 10:
                print("  too short; hold the key while you mouth the words")
                return
            self.macos.sound("Pop")
            self.handle(frames, anchors, stamps)

    def handle(self, frames, anchors, stamps):
        from . import clip
        seen = sum(a is not None for a in anchors)
        if seen < len(anchors) * 0.5:
            print(f"  face seen in only {seen}/{len(anchors)} frames; face the camera with your mouth in view")
            if seen == 0:
                return
        guesses, timing = clip.read(self.reader, frames, anchors, stamps, nbest=5)
        if not guesses:
            print("  nothing read")
            return
        t = time.perf_counter()
        text = self.cleaner(guesses, list(self.recent))
        timing["cleanup"] = time.perf_counter() - t
        print(f"  lips:  {guesses[0]}")
        print(f"  text:  {text}")
        print("  " + "  ".join(f"{k} {v:.2f}s" for k, v in timing.items() if k != "frames")
              + f"  ({timing['frames']} frames)")
        if not text:
            return
        self.recent.append(text)
        if self.args.copy_only:
            self.macos.copy(text)
        else:
            self.macos.paste(text + " ")


def run(args):
    from . import macos
    from .cleanup import Cleaner
    missing = [p for p in ("vsr/model.pth", "lm/model.pth", "face_landmarker.task") if not (MODELS / p).exists()]
    if missing:
        sys.exit(f"Models missing: {', '.join(missing)}. Run ./scripts/download-models.sh first.")
    reader = load_reader(args)
    cleaner = Cleaner(args.cleanup)
    print(f"Cleanup: {cleaner.mode}" + ("" if cleaner.mode == "claude" else
          "  (set ANTHROPIC_API_KEY for Claude cleanup, which fixes far more mis-read words)"))
    if not args.copy_only and not macos.accessibility_trusted():
        print("Pasting needs Accessibility: System Settings > Privacy & Security > Accessibility, add this "
              "Terminal app, then restart it. Until then the text is only copied.")
        args.copy_only = True
    app = Dictation(args, reader, cleaner)
    key = args.key.replace("_", " ")
    print(f"\nReady. Hold {key}, silently mouth what you want to type, then release. Esc cancels. Ctrl+C quits.\n")
    try:
        macos.HoldKey(args.key, app.on_down, app.on_up, app.on_cancel).run()
    except KeyboardInterrupt:
        pass
    finally:
        app.camera.close()


def read_file(args):
    from . import clip
    from .cleanup import Cleaner
    from .face import FaceTracker
    reader = load_reader(args)
    frames, stamps = clip.frames_from_file(args.video, args.start, args.end)
    tracker = FaceTracker(MODELS / "face_landmarker.task")
    anchors = clip.track(tracker, frames, stamps)
    guesses, timing = clip.read(reader, frames, anchors, stamps)
    for i, g in enumerate(guesses, 1):
        print(f"{i}. {g}")
    print("text:", Cleaner(args.cleanup)(guesses))
    print({k: round(v, 2) for k, v in timing.items()})


def _camera(value):
    return int(value) if value.isdigit() else value


def main(argv=None):
    from .macos import KEYS
    p = argparse.ArgumentParser(prog="lip-dictation", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--key", choices=sorted(KEYS), default="right_option", help="hold-to-talk key")
    p.add_argument("--camera", type=_camera, default=0,
                   help="camera index (0 is usually the built-in one), or a video file to stand in for it")
    p.add_argument("--cleanup", choices=["auto", "claude", "basic"], default="auto")
    p.add_argument("--beam", type=int, default=10, help="beam size: higher is slower, slightly more accurate")
    p.add_argument("--copy-only", action="store_true", help="copy the text instead of pasting it")
    sub = p.add_subparsers(dest="command")
    f = sub.add_parser("file", help="lip-read a video file")
    f.add_argument("video")
    f.add_argument("--start", type=float, default=0.0)
    f.add_argument("--end", type=float, default=None)
    args = p.parse_args(argv)
    if args.command == "file":
        read_file(args)
    else:
        run(args)


if __name__ == "__main__":
    main()
