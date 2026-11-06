"""Word error rate of the lip reader under different settings, with 95% confidence intervals.

  # the subtitled news clips (samples/*.mov with .srt next to them)
  .venv/bin/python scripts/eval_vsr.py news --align points8,anchors4 --beam 10,20,40 --lm 0.3,0.6
  # your own silent test set, recorded with scripts/record_test_set.py
  .venv/bin/python scripts/eval_vsr.py testsets/silent --rate 1.0,1.2,1.4 --context models/text-lm

Every combination of --align, --rate, --beam, --lm and --ctc is scored on the same sentences.
The first combination is the baseline: each row also shows its change against it, and whether
that change is clear of noise (a paired bootstrap over sentences). Faces are tracked once per
clip, on grayscale frames like the app, and cached in <set>/.cache.

--rate speeds up the mouth video before reading it (1.2 = 20% faster), since people mouth more
slowly than they speak. --context also runs the on-device language-model step; for the news
clips the previous sentence is the text before the cursor, for a test set there is none.
"""
import argparse
import itertools
import json
import os
import re
import sys
import time
from pathlib import Path

import numpy as np
import torch

os.environ.setdefault("GLOG_minloglevel", "2")
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
import cv2  # noqa: E402
import jiwer  # noqa: E402
from num2words import num2words  # noqa: E402

from lipdictation import clip, face  # noqa: E402
from lipdictation.vsr import LipReader  # noqa: E402


def norm(t):
    t = re.sub(r"\d+", lambda m: " " + num2words(int(m.group())) + " ", t)
    t = t.lower().replace("-", " ").replace("'", "").replace("’", "")
    return " ".join(re.sub(r"[^a-z ]", " ", t).split())


def sentences(name):
    """[(video, start, end, truth, key)] for "news" or a test-set folder."""
    if name == "news":
        from eval_cache import units
        return [(v, s, e, t, f"{v.stem}-{s:.2f}") for v in sorted((ROOT / "samples").glob("*.mov"))
                if v.with_suffix(".srt").exists() for s, e, t in units(v.with_suffix(".srt"))]
    folder = Path(name)
    return [(v, 0.0, None, v.with_suffix(".txt").read_text().strip(), v.stem)
            for v in sorted(folder.glob("*.mp4")) if v.with_suffix(".txt").exists()]


def crops_by_align(units, aligns, cache_dir):
    """{key: {align: crops}}; faces are tracked once per clip and the crops cached."""
    cache_dir.mkdir(exist_ok=True)
    tracker = None
    out = {}
    for video, start, end, truth, key in units:
        path = cache_dir / f"{key}.npz"
        have = dict(np.load(path)) if path.exists() else {}
        if not all(a in have for a in aligns):
            frames, stamps = clip.frames_from_file(video, start, end)
            if len(frames) < 15:
                continue
            if tracker is None:
                tracker = face.FaceTracker(ROOT / "models" / "face_landmarker.task")
            gray = [cv2.cvtColor(f, cv2.COLOR_RGB2GRAY) for f in frames]
            marks = [tracker.anchors(np.repeat(g[:, :, None], 3, axis=2), t * 1000) for g, t in zip(gray, stamps)]
            if sum(m is not None for m in marks) < len(marks) * 0.8:
                np.savez_compressed(path, skip=np.zeros(1))     # cutaways without the speaker
                continue
            keep = face.resample(list(range(len(frames))), stamps)
            for a in aligns:
                have[a] = face.mouth_crops([gray[i] for i in keep], [marks[i] for i in keep], align=a)
            np.savez_compressed(path, **have)
        if "skip" not in have:
            out[key] = {a: have[a] for a in aligns}
    if tracker:
        tracker.close()
    return out


def speed_up(crops, rate):
    if rate == 1.0:
        return crops
    idx = np.round(np.arange(0, len(crops) - 0.5, rate)).astype(int)
    return crops[np.clip(idx, 0, len(crops) - 1)]


def errors(ref, hyp):
    o = jiwer.process_words(ref, hyp)
    return o.substitutions + o.deletions + o.insertions


def interval(err, n, rng, base=None):
    """WER and its 95% bootstrap interval; with base, the interval of the change against it."""
    err, n = np.asarray(err, float), np.asarray(n, float)
    picks = rng.integers(0, len(n), size=(2000, len(n)))
    if base is None:
        boot = err[picks].sum(1) / n[picks].sum(1)
    else:
        base = np.asarray(base, float)
        boot = (err[picks].sum(1) - base[picks].sum(1)) / n[picks].sum(1)
    return np.percentile(boot, [2.5, 97.5])


@torch.no_grad()
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("set", help='"news" or a folder of NNN.mp4 + NNN.txt')
    ap.add_argument("--align", default="anchors4")
    ap.add_argument("--rate", default="1.0")
    ap.add_argument("--beam", default="10")
    ap.add_argument("--lm", default="0.3")
    ap.add_argument("--ctc", default="0.1")
    ap.add_argument("--context", help="text language model folder, e.g. models/text-lm")
    ap.add_argument("--show", action="store_true", help="print every reading of the first setting")
    a = ap.parse_args()
    floats = lambda s: [float(x) for x in s.split(",")]
    aligns = a.align.split(",")

    units = sentences(a.set)
    cache_dir = (ROOT / "samples" if a.set == "news" else Path(a.set)) / ".cache"
    crops = crops_by_align(units, aligns, cache_dir)
    units = [u for u in units if u[4] in crops]
    refs = [norm(u[3]) for u in units]
    words = [len(r.split()) for r in refs]
    print(f"{len(units)} sentences, {sum(words)} words", flush=True)

    reader = LipReader(ROOT / "models")
    corrector = None
    if a.context:
        from lipdictation.context import Corrector
        corrector = Corrector(a.context)
    rng = np.random.default_rng(0)
    base_err = base_ctx = None
    results = []
    for align, rate in itertools.product(aligns, floats(a.rate)):
        feats = {u[4]: reader.encode(speed_up(crops[u[4]][align], rate)) for u in units}
        for beam, lm, ctc in itertools.product(floats(a.beam), floats(a.lm), floats(a.ctc)):
            reader.configure(beam_size=int(beam), lm_weight=lm, ctc_weight=ctc)
            err, ctx_err, search = [], [], []
            prev = ""
            for u, ref in zip(units, refs):
                t0 = time.perf_counter()
                hyps = reader.beam(feats[u[4]])
                search.append(time.perf_counter() - t0)
                scored, seen = [], set()
                for h in hyps:
                    text = reader._text(h)
                    if text and text not in seen:
                        seen.add(text)
                        scored.append((text, float(h.score)))
                    if len(scored) == 10:
                        break
                hyp = norm(scored[0][0]) if scored else ""
                err.append(errors(ref, hyp))
                if corrector and scored:
                    fixed, _ = corrector.correct(scored, prev if a.set == "news" else "")
                    ctx_err.append(errors(ref, norm(fixed)))
                if a.show and not results:
                    print(f"  {ref}\n  {hyp}\n")
                prev = u[3]
            setting = dict(align=align, rate=rate, beam=int(beam), lm=lm, ctc=ctc)
            row = dict(setting, wer=sum(err) / sum(words), ci=interval(err, words, rng).round(3).tolist(),
                       search=round(float(np.mean(search)), 2))
            if base_err is None:
                base_err = err
            else:
                row["change_ci"] = interval(err, words, rng, base_err).round(3).tolist()
            if corrector:
                row["wer_context"] = sum(ctx_err) / sum(words)
                if base_ctx is None:
                    base_ctx = ctx_err
                else:
                    row["context_change_ci"] = interval(ctx_err, words, rng, base_ctx).round(3).tolist()
            results.append(row)
            clear = ""
            if "change_ci" in row:
                lo, hi = row["change_ci"]
                clear = "  better" if hi < 0 else "  worse" if lo > 0 else "  (within noise)"
            ctx = f"  context {row['wer_context']:.3f}" if corrector else ""
            print(f"{setting}: WER {row['wer']:.3f} [{row['ci'][0]:.3f}-{row['ci'][1]:.3f}]{ctx}"
                  f"  search {row['search']}s{clear}", flush=True)
    (cache_dir / "results.json").write_text(json.dumps(results, indent=1))


if __name__ == "__main__":
    main()
