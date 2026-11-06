"""Record a personal test set: you silently mouth prompted sentences and each one is saved
as a video with its text, so every change to the lip reader can be measured on the real task.

  .venv/bin/python scripts/record_test_set.py testsets/silent
  .venv/bin/python scripts/eval_vsr.py testsets/silent

Space starts and stops a recording, R records the last sentence again, S skips a sentence,
Q quits. Run it again later to add more: it carries on where you stopped. Recording over a
few sessions, at different times of day, makes the measurement closer to everyday use.

The videos are of your face. They stay in the folder you give (testsets/ is ignored by git);
don't share or commit them.
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

os.environ.setdefault("GLOG_minloglevel", "2")
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import cv2  # noqa: E402
import numpy as np  # noqa: E402

from lipdictation.face import FaceTracker  # noqa: E402

WINDOW = "Lip Dictation test set"


def prompts(path):
    return [l.strip() for l in Path(path).read_text().splitlines() if l.strip() and not l.startswith("#")]


def save(folder, index, frames, stamps, sentence, camera):
    fps = (len(frames) - 1) / (stamps[-1] - stamps[0])
    h, w = frames[0].shape[:2]
    out = cv2.VideoWriter(str(folder / f"{index:03d}.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    for f in frames:
        out.write(f)
    out.release()
    (folder / f"{index:03d}.txt").write_text(sentence + "\n")
    (folder / f"{index:03d}.json").write_text(json.dumps(
        dict(mode="silent", fps=round(fps, 2), seconds=round(stamps[-1] - stamps[0], 2), camera=camera,
             recorded=datetime.now().isoformat(timespec="seconds"))))


def draw(view, lines, recording, face_ok):
    h, w = view.shape[:2]
    cv2.rectangle(view, (0, h - 34 * len(lines) - 20), (w, h), (0, 0, 0), -1)
    for i, (text, scale) in enumerate(lines):
        cv2.putText(view, text, (20, h - 34 * (len(lines) - i) + 6), cv2.FONT_HERSHEY_SIMPLEX, scale,
                    (255, 255, 255), 2, cv2.LINE_AA)
    if recording:
        cv2.circle(view, (40, 40), 14, (40, 40, 230), -1)
    if not face_ok:
        cv2.putText(view, "Can't see your mouth", (70, 50), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 165, 255), 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", nargs="?", default=str(ROOT / "testsets" / "silent"))
    ap.add_argument("--camera", type=int, default=0)
    ap.add_argument("--sentences", default=str(ROOT / "scripts" / "test-sentences.txt"))
    a = ap.parse_args()
    folder = Path(a.folder)
    folder.mkdir(parents=True, exist_ok=True)

    done = {p.read_text().strip() for p in folder.glob("*.txt")}
    todo = [s for s in prompts(a.sentences) if s not in done]
    index = max([int(p.stem) for p in folder.glob("*.mp4")] + [-1]) + 1
    if not todo:
        print("Every sentence is recorded. Add more to", a.sentences)
        return

    cap = cv2.VideoCapture(a.camera)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    if not cap.isOpened():
        sys.exit("Couldn't open the camera. Allow your terminal app in System Settings › Privacy & Security › Camera.")
    tracker = FaceTracker(ROOT / "models" / "face_landmarker.task")
    cv2.namedWindow(WINDOW)
    recording, frames, stamps, last = False, [], [], None
    seen = []
    t0 = time.monotonic()
    while todo:
        ok, frame = cap.read()
        if not ok:
            continue
        now = time.monotonic()
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        face_ok = tracker.anchors(np.repeat(gray[:, :, None], 3, axis=2), (now - t0) * 1000) is not None
        if recording:
            frames.append(frame)
            stamps.append(now)
            seen.append(face_ok)
        view = cv2.flip(frame, 1)       # a mirror is easier to watch; the saved video isn't flipped
        state = "Recording: mouth it silently, then press Space" if recording else \
            "Space: record   R: redo last   S: skip   Q: quit"
        draw(view, [(f"{index:03d}  {todo[0]}", 0.9), (state, 0.6)], recording, face_ok)
        cv2.imshow(WINDOW, view)
        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            break
        if key == ord("s") and not recording:
            todo.append(todo.pop(0))
        if key == ord("r") and not recording and last:
            index -= 1
            todo.insert(0, last)
            last = None
        if key == ord(" "):
            if not recording:
                recording, frames, stamps, seen = True, [], [], []
            else:
                recording = False
                if len(frames) < 15:
                    print("Too short, try again.")
                elif sum(seen) < len(seen) * 0.8:
                    print("Your mouth was out of view for part of it, try again.")
                else:
                    save(folder, index, frames, stamps, todo[0], a.camera)
                    print(f"{index:03d}  {todo[0]}")
                    last = todo.pop(0)
                    index += 1
    cap.release()
    tracker.close()
    cv2.destroyAllWindows()
    print(f"{len(list(folder.glob('*.mp4')))} sentences in {folder}. Measure with:\n"
          f"  .venv/bin/python scripts/eval_vsr.py {folder}")


if __name__ == "__main__":
    main()
