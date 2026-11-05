"""Runs the lip reader over subtitled clips and caches its scored guesses, so the
context step can be tuned without re-reading video.

  .venv/bin/python scripts/eval_cache.py samples/2016-03-12.mov samples/2017-01-07.mov
Writes samples/eval-cache.json: [{clip, start, end, truth, nbest: [[text, score], ...]}].
"""
import json
import os
import re
import sys
from pathlib import Path

os.environ.setdefault("GLOG_minloglevel", "2")
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from lipdictation import clip, face  # noqa: E402
from lipdictation.vsr import LipReader  # noqa: E402


def stamp(s):
    h, m, rest = s.strip().split(":")
    sec, ms = (rest.split(",") + ["0"])[:2]
    return int(h) * 3600 + int(m) * 60 + int(sec) + int(ms.ljust(3, "0")[:3]) / 1000


def units(srt_path, max_len=12.0):
    """Runs of subtitle cues that end at a sentence end."""
    cues = []
    for block in Path(srt_path).read_text().strip().split("\n\n"):
        lines = block.strip().splitlines()
        if len(lines) < 3 or "-->" not in lines[1]:
            continue
        a, b = lines[1].split("-->")
        text = " ".join(lines[2:])
        text = re.sub(r"^(The President|THE PRESIDENT):\s*", "", text)
        cues.append((stamp(a), stamp(b), text))
    out, cur = [], []
    for c in cues:
        cur.append(c)
        if re.search(r"[.?!]\"?$", c[2].strip()) or cur[-1][1] - cur[0][0] > max_len:
            out.append((cur[0][0], cur[-1][1], " ".join(x[2] for x in cur)))
            cur = []
    return out


def main():
    reader = LipReader(ROOT / "models", beam_size=10)
    cache = []
    for video in sys.argv[1:]:
        srt = Path(video).with_suffix(".srt")
        for start, end, truth in units(srt):
            frames, stamps = clip.frames_from_file(video, start, end)
            if len(frames) < 15:
                continue
            tracker = face.FaceTracker(ROOT / "models" / "face_landmarker.task")
            anchors = clip.track(tracker, frames, stamps)
            tracker.close()
            if sum(a is not None for a in anchors) < len(anchors) * 0.8:
                continue                                  # cutaways without the speaker
            crops = clip.crops_for(frames, anchors, stamps)
            nbest, _ = reader.read_scored(crops, nbest=10)
            cache.append({"clip": Path(video).name, "start": start, "end": end, "truth": truth, "nbest": nbest})
            print(f"{start:6.1f} {truth[:60]!r} -> {nbest[0][0][:60] if nbest else ''!r}", flush=True)
    (ROOT / "samples" / "eval-cache.json").write_text(json.dumps(cache, indent=1))
    print(len(cache), "units")


if __name__ == "__main__":
    main()
