"""Word error rate of the lip reader alone vs with the context step, on cached readings.

  .venv/bin/python scripts/eval_context.py models/text-qwen2.5-0.5b [--grid]
Needs samples/eval-cache.json from scripts/eval_cache.py. Context for each sentence is the
previous sentence of the transcript, as if it were already typed before the cursor.
"""
import json
import os
import re
import sys
from pathlib import Path

os.environ.setdefault("GLOG_minloglevel", "2")
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import jiwer  # noqa: E402
from num2words import num2words  # noqa: E402

from lipdictation.context import Corrector  # noqa: E402


def norm(t):
    t = re.sub(r"\d+", lambda m: " " + num2words(int(m.group())) + " ", t)
    t = t.lower().replace("-", " ").replace("'", "").replace("’", "")
    return " ".join(re.sub(r"[^a-z ]", " ", t).split())


def run(c, cache, use_context=True, show=False):
    refs, base, fixed = [], [], []
    prev = ""
    for u in cache:
        ctx = prev if use_context else ""
        text, _ = c.correct([tuple(x) for x in u["nbest"]], ctx)
        refs.append(norm(u["truth"]))
        base.append(norm(u["nbest"][0][0]))
        fixed.append(norm(text))
        if show and base[-1] != fixed[-1]:
            print(f"  {base[-1]!r}\n   -> {fixed[-1]!r}\n  truth {refs[-1]!r}")
        prev = u["truth"]
    return jiwer.wer(refs, base), jiwer.wer(refs, fixed)


def main():
    cache = json.loads((ROOT / "samples" / "eval-cache.json").read_text())
    c = Corrector(sys.argv[1])
    memo = {}
    raw = c.lm_logprob

    def cached(sentences, context=""):
        todo = [s for s in sentences if (context, s) not in memo]
        if todo:
            for s, lp in zip(todo, raw(todo, context)):
                memo[(context, s)] = lp
        return [memo[(context, s)] for s in sentences]
    c.lm_logprob = cached

    if "--grid" in sys.argv:
        grid = [dict(word_bonus=wb, vsr_weight=vw) for wb in (0.5, 1.5, 2.5) for vw in (0.15, 0.3, 0.6)]
        if "--costs" in sys.argv:
            grid = [dict(same_cost=sc, near_cost=nc, lm_weight=lw) for sc in (1.5, 3.0) for nc in (4.0, 7.0)
                    for lw in (0.4, 0.8)]
        for g in grid:
            for k, v in g.items():
                setattr(c, k, v)
            b, f = run(c, cache)
            print(f"{g}: {b:.3f} -> {f:.3f}", flush=True)
    else:
        b, f = run(c, cache, show=True)
        print(f"WER lips alone {b:.3f} -> with context {f:.3f}")
        b, f = run(c, cache, use_context=False)
        print(f"without previous sentence: {b:.3f} -> {f:.3f}")


if __name__ == "__main__":
    main()
