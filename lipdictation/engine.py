"""The lip-reading engine the Mac app runs as a child process.

The app owns the camera (so macOS permissions belong to the app) and streams
frames in; the engine tracks the face as they arrive, and on "end" reads the
lips, cleans the text up and answers with the result.

stdin, repeated:  4-byte big-endian header length, the JSON header, then
                  header["n"] payload bytes when the header has "n".
  {"type": "config", "cleanup": "auto|claude|basic", "api_key": "...", "beam": 10, "words": ["Rohit", ...],
   "corrections": [["luke", "Rohit", 2], ...]}            your dictionary: heard, fixed, times fixed
  {"type": "begin", "id": 7}
  {"type": "frame", "t": 12.345, "w": 640, "h": 480, "n": 307200}   + 8-bit grayscale pixels
  {"type": "end", "id": 7, "recent": ["previous dictation", ...], "context": "text before the cursor", "app": "Mail"}
  {"type": "cancel"}
  {"type": "learn", "inserted": "I bought a new PS.", "edited": "I bought a new PS5."}
stdout, one JSON object per line:
  {"type": "status", "message": "..."}       while loading
  {"type": "ready", "gpu": true}
  {"type": "face", "seen": true}            a few times a second while recording
  {"type": "result", "id": 7, "text": "...", "guesses": [...], "contextual": "...", "timing": {...}}
  {"type": "learned", "pairs": [["ps", "PS5"]]}     your fixes, for the app to keep
  {"type": "error", "id": 7, "message": "..."}
"""
import argparse
import json
import os
import struct
import sys
import time
import traceback

os.environ.setdefault("GLOG_minloglevel", "2")
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

MIN_FRAMES = 12          # under half a second is an accidental tap
FACE_EVERY = 6           # frames between face reports


def send(**msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def messages(stream):
    while True:
        raw = stream.read(4)
        if len(raw) < 4:
            return
        (size,) = struct.unpack(">I", raw)
        header = json.loads(stream.read(size))
        payload = stream.read(header["n"]) if header.get("n") else b""
        yield header, payload


class Engine:
    def __init__(self, models):
        import numpy as np
        from .cleanup import Cleaner
        from .face import FaceTracker
        from .vsr import LipReader
        self.np = np
        send(type="status", message="Loading the lip reader…")
        self.reader = LipReader(models)
        self.tracker = FaceTracker(os.path.join(models, "face_landmarker.task"))
        self.cleaner = Cleaner("basic")
        from .learning import Fixes, load_community
        self.words = []
        self.fixes = Fixes()
        self.community = load_community()
        self.fixes.set(community=self.community)
        self.corrector = None
        text_lm = os.path.join(models, "text-lm")
        if os.path.exists(os.path.join(text_lm, "model.safetensors")):
            send(type="status", message="Loading the language model…")
            try:
                from .context import Corrector
                self.corrector = Corrector(text_lm)
                self.corrector.fixes = self.fixes
            except Exception:
                traceback.print_exc()          # lip reading still works without it
        self.reset()
        send(type="ready", gpu=self.reader.gpu is not None, context=self.corrector is not None)

    def reset(self, ident=None):
        self.id = ident
        self.frames, self.anchors, self.stamps = [], [], []
        self.seen_recently = []

    def config(self, msg):
        from .cleanup import Cleaner
        self.cleaner = Cleaner(msg.get("cleanup", "auto"), msg.get("api_key") or None)
        if msg.get("beam"):
            self.reader.beam.beam_size = int(msg["beam"])
        self.fixes.set(personal=[(h, f, int(c)) for h, f, c in msg.get("corrections") or []],
                       community=self.community)
        self.words = [w for w in msg.get("words") or [] if w.strip()] + self.fixes.words()
        if self.corrector:
            self.corrector.set_words(self.words)
        send(type="configured", cleanup=self.cleaner.mode)

    def frame(self, msg, payload):
        np = self.np
        gray = np.frombuffer(payload, np.uint8).reshape(msg["h"], msg["w"])
        anchors = self.tracker.anchors(np.repeat(gray[:, :, None], 3, axis=2), msg["t"] * 1000)
        self.frames.append(gray)
        self.anchors.append(anchors)
        self.stamps.append(msg["t"])
        self.seen_recently.append(anchors is not None)
        if len(self.seen_recently) >= FACE_EVERY:
            send(type="face", seen=sum(self.seen_recently) * 2 > len(self.seen_recently))
            self.seen_recently = []

    def end(self, msg):
        from . import face
        frames, anchors, stamps, ident = self.frames, self.anchors, self.stamps, msg.get("id", self.id)
        self.reset()
        if len(frames) < MIN_FRAMES:
            return send(type="error", id=ident, kind="short", message="Too short. Hold the key while you mouth the words.")
        seen = sum(a is not None for a in anchors)
        if seen == 0:
            return send(type="error", id=ident, kind="face",
                        message="Couldn't see your face. Face the camera with your mouth in view.")
        t0 = time.perf_counter()
        keep = face.resample(list(range(len(frames))), stamps)
        crops = face.mouth_crops([frames[i] for i in keep], [anchors[i] for i in keep])
        t1 = time.perf_counter()
        scored, timing = self.reader.read_scored(crops, nbest=10)
        timing["crop"] = t1 - t0
        if not scored:
            return send(type="error", id=ident, kind="empty", message="Couldn't make out any words. Try again.")
        guesses = [t for t, _ in scored]
        recent = msg.get("recent") or []
        context = (msg.get("context") or "").strip() or " ".join(recent)
        best = guesses[0]
        if not self.corrector and self.fixes.items:
            from .learning import apply_simple
            best = apply_simple(best, self.fixes)
        if self.corrector:
            t2 = time.perf_counter()
            best, info = self.corrector.correct(scored, context[-400:])
            timing["context"] = time.perf_counter() - t2
        t3 = time.perf_counter()
        text = self.cleaner(guesses[:5], recent, best=best, context=context, app=msg.get("app") or "",
                            words=self.words)
        timing["cleanup"] = time.perf_counter() - t3
        send(type="result", id=ident, text=text, guesses=guesses[:5], contextual=best, cleanup=self.cleaner.mode,
             face=seen / len(anchors), timing={k: round(v, 3) for k, v in timing.items()})


def main(argv=None):
    p = argparse.ArgumentParser(description="Lip Dictation engine (spoken to by the Mac app over stdin/stdout)")
    p.add_argument("--models", required=True)
    args = p.parse_args(argv)
    try:
        engine = Engine(args.models)
    except Exception as e:
        traceback.print_exc()
        send(type="fatal", message=f"The lip reader didn't start: {e}")
        return 1
    for msg, payload in messages(sys.stdin.buffer):
        kind = msg.get("type")
        try:
            if kind == "frame":
                engine.frame(msg, payload)
            elif kind == "begin":
                engine.reset(msg.get("id"))
            elif kind == "end":
                engine.end(msg)
            elif kind == "cancel":
                engine.reset()
            elif kind == "config":
                engine.config(msg)
            elif kind == "learn":
                from .learning import extract
                pairs = extract(msg.get("inserted") or "", msg.get("edited") or "")
                send(type="learned", pairs=[list(p) for p in pairs])
            elif kind == "ping":
                send(type="pong")
        except Exception as e:
            traceback.print_exc()
            engine.reset()
            send(type="error", id=msg.get("id"), kind="crash", message=f"Something went wrong: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
