"""Turns "Shared fixes" GitHub issues into input for scripts/merge-community.py.

  gh issue list --search '"lip-dictation-fixes v1" in:body' --state all --limit 1000 \
      --json number,author,body > issues.json
  python3 scripts/collect-shared-fixes.py issues.json > shared-fixes.jsonl

Issue text is untrusted: only the JSON block after the marker is read, every field is checked,
and each GitHub account counts once per fix, so one person can't push a fix in alone.
"""
import json
import re
import sys

MARKER = "lip-dictation-fixes v1"
BLOCK = re.compile(r"<!--\s*" + re.escape(MARKER) + r"\s*-->\s*```(?:json)?\s*(\{.*?\})\s*```", re.S)
HEARD = re.compile(r"[a-z0-9']+(?: [a-z0-9']+){0,2}")          # what a lip reader writes: 1-3 lowercase words
FIXED = re.compile(r"[A-Za-z0-9][A-Za-z0-9'.&+-]*(?: [A-Za-z0-9][A-Za-z0-9'.&+-]*){0,2}")
PER_ISSUE = 80


def fixes_in(issue):
    m = BLOCK.search(issue.get("body") or "")
    if not m:
        return []
    try:
        data = json.loads(m.group(1))
    except ValueError:
        return []
    out = []
    for f in (data.get("fixes") or [])[:PER_ISSUE]:
        if not isinstance(f, dict):
            continue
        heard, fixed = str(f.get("heard", "")).strip(), str(f.get("fixed", "")).strip()
        if (HEARD.fullmatch(heard) and FIXED.fullmatch(fixed) and len(fixed) <= 40
                and heard != fixed.lower()):
            out.append((heard, fixed))
    return out


def main():
    issues = json.load(open(sys.argv[1]))
    for issue in issues:
        who = (issue.get("author") or {}).get("login")
        if not who:
            continue
        for heard, fixed in fixes_in(issue):
            print(json.dumps({"install": who, "heard": heard, "fixed": fixed, "issue": issue.get("number")}))


if __name__ == "__main__":
    main()
