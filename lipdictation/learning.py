"""Learning from your corrections.

When you fix a word Lip Dictation typed ("PS" → "PS5", "Luke" → "Rohit"), the app sends
what it typed and what the text became. `extract` finds the words you replaced. The pairs go
into your personal dictionary, and next time the lip reader reads "ps" or "luke", the fix is
offered to the context step with a strong preference, so it wins unless the sentence clearly
says otherwise. The more often you make the same fix, the stronger it gets.

The shared dictionary (data/community.tsv) works the same way with a weaker preference: fixes
that many people made, shipped with app updates so everyone benefits.
"""
from difflib import SequenceMatcher
from pathlib import Path

DATA = Path(__file__).parent / "data"
MAX_PHRASE = 3          # words on either side of a fix


def _clean(token):
    """A word as typed, without surrounding punctuation ("PS5." → "PS5")."""
    return token.strip(".,!?;:\"“”()[]{}")


def _norm(token):
    return _clean(token).lower()


def extract(inserted, edited):
    """[(heard, fixed)] for the words you replaced in what was typed.

    heard is lowercase (as the lip reader writes it); fixed keeps your spelling and capitals.
    Text you typed after the dictation is ignored, and so is a complete rewrite, which is
    a different sentence rather than a correction."""
    a = [t for t in inserted.split() if _norm(t)]
    b = [t for t in edited.split() if _norm(t)]
    if not a or not b:
        return []
    ops = SequenceMatcher(None, [_norm(t) for t in a], [_norm(t) for t in b], autojunk=False).get_opcodes()
    pairs, changed = [], 0
    for tag, i1, i2, j1, j2 in ops:
        if tag == "replace":
            if i2 == len(a) and j2 - j1 > i2 - i1:
                j2 = j1 + (i2 - i1)                # the rest is you typing on after the dictation
            changed += max(i2 - i1, j2 - j1)
            if i2 - i1 <= MAX_PHRASE and j2 - j1 <= MAX_PHRASE:
                heard = " ".join(_norm(t) for t in a[i1:i2])
                fixed = " ".join(_clean(t) for t in b[j1:j2])
                if heard and fixed and heard != fixed.lower():
                    pairs.append((heard, fixed))
        elif tag == "delete":
            changed += i2 - i1
        elif tag == "insert" and i1 < len(a):     # inserting at the end is just typing on
            changed += j2 - j1
    if changed > max(2, len(a) // 2):
        return []
    return pairs


def load_community(path=DATA / "community.tsv", min_people=3):
    """[(heard, fixed, people)] from the shared dictionary, fixes made by enough people."""
    out = []
    if not Path(path).exists():
        return out
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        heard, fixed, people = line.rstrip("\n").split("\t")
        if int(people) >= min_people:
            out.append((heard, fixed, int(people)))
    return out


class Fixes:
    """Your fixes plus the shared ones, ready to apply to a reading."""

    def __init__(self):
        self.items = {}         # heard words (tuple) -> [(fixed, bonus)]

    def set(self, personal=(), community=()):
        self.items = {}
        for heard, fixed, people in community:
            self._add(heard, fixed, 1.5 + min(people, 20) * 0.1)
        for heard, fixed, count in personal:
            self._add(heard, fixed, 4.0 + 2.0 * min(count - 1, 3))     # 4 the first time, up to 10

    def _add(self, heard, fixed, bonus):
        key = tuple(heard.lower().split())
        if key:
            self.items.setdefault(key, []).append((fixed, bonus))

    def words(self):
        """Your fixed spellings, so the formatting keeps them ("PS5", "Rohit")."""
        return sorted({f for fixes in self.items.values() for f, _ in fixes}, key=len, reverse=True)

    def apply(self, words):
        """[(new words, bonus)]: the reading with each matching fix applied (one fix each)."""
        out = []
        n = len(words)
        for key, fixes in self.items.items():
            k = len(key)
            for i in range(n - k + 1):
                if tuple(words[i:i + k]) == key:
                    for fixed, bonus in fixes:
                        out.append((words[:i] + fixed.split() + words[i + k:], bonus))
        return out


def apply_simple(text, fixes):
    """Without the language model: apply every matching fix (strongest first) to a lowercase reading."""
    words = text.lower().split()
    for key, options in sorted(fixes.items.items(), key=lambda kv: -len(kv[0])):
        fixed = max(options, key=lambda o: o[1])[0]
        i = 0
        while i <= len(words) - len(key):
            if tuple(words[i:i + len(key)]) == key:
                words[i:i + len(key)] = fixed.split()
                i += len(fixed.split())
            else:
                i += 1
    return " ".join(words)

