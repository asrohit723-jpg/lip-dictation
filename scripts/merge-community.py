"""Builds the shared dictionary (lipdictation/data/community.tsv) from fixes people chose to share.

  .venv/bin/python scripts/merge-community.py shared-fixes.jsonl [--min-people 3]

Input: one JSON object per line, {"install": "<random id per Mac>", "heard": "ps", "fixed": "PS5"}.
A fix goes in once enough different Macs made it, which keeps out personal names and one-offs.
The app applies shared fixes with a weaker preference than your own.
"""
import argparse
import json
from collections import defaultdict
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "lipdictation" / "data" / "community.tsv"
HEADER = ("# Shared dictionary: lip-reading fixes many people made. heard<TAB>fixed<TAB>people\n"
          "# Built by scripts/merge-community.py from shared corrections; applied once 3 or more people made a fix.\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("inputs", nargs="+")
    p.add_argument("--min-people", type=int, default=3)
    args = p.parse_args()
    people = defaultdict(set)                       # (heard, fixed) -> installs
    for path in args.inputs:
        for line in open(path, encoding="utf-8"):
            try:
                r = json.loads(line)
                heard, fixed, who = r["heard"].strip().lower(), r["fixed"].strip(), r["install"]
            except (ValueError, KeyError, AttributeError):
                continue
            if heard and fixed and 0 < len(heard.split()) <= 3 and len(fixed) <= 40:
                people[(heard, fixed)].add(who)
    # for each misreading keep the fix most people agreed on
    best = {}
    for (heard, fixed), who in people.items():
        if len(who) >= args.min_people and len(who) > len(best.get(heard, ("", set()))[1]):
            best[heard] = (fixed, who)
    rows = sorted(best.items(), key=lambda kv: -len(kv[1][1]))
    OUT.write_text(HEADER + "".join(f"{h}\t{f}\t{len(w)}\n" for h, (f, w) in rows), encoding="utf-8")
    print(f"{len(rows)} shared fixes -> {OUT}")


if __name__ == "__main__":
    main()
