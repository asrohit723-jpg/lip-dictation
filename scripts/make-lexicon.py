"""Builds lipdictation/data/lexicon.tsv: common English words, their lip shapes and frequency.

  .venv/bin/pip install wordfreq && .venv/bin/python scripts/make-lexicon.py cmudict.dict

Inputs: the CMU Pronouncing Dictionary (github.com/cmusphinx/cmudict, BSD licence) and word
frequencies from wordfreq (data CC BY-SA 4.0). Output columns: word, viseme string, Zipf frequency.
"""
import re
import sys
from pathlib import Path

from wordfreq import top_n_list, zipf_frequency

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from lipdictation.visemes import to_visemes  # noqa: E402

TOP = 60000          # most frequent English words considered
MIN_ZIPF = 2.5       # roughly "seen once per 3 million words"

common = {w for w in top_n_list("en", TOP) if re.fullmatch(r"[a-z]+(?:'[a-z]+)?", w)}
seen = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.split("#")[0].strip()
    if not line:
        continue
    word, *phones = line.split()
    word = re.sub(r"\(\d+\)$", "", word)          # alternative pronunciations: keep the first
    if word in seen or word not in common:
        continue
    z = zipf_frequency(word, "en")
    if z >= MIN_ZIPF:
        seen[word] = (to_visemes(phones), z)

out = Path(__file__).resolve().parent.parent / "lipdictation" / "data" / "lexicon.tsv"
with open(out, "w") as f:
    for word, (vis, z) in sorted(seen.items(), key=lambda kv: -kv[1][1]):
        f.write(f"{word}\t{vis}\t{z:.2f}\n")
print(f"{len(seen)} words -> {out}")
