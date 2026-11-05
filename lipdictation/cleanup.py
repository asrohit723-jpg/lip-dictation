"""Turn the lip reader's guesses into the finished sentence.

By the time text gets here, the context step (context.py) has already picked the
reading that makes sense. With Claude credentials available, Claude gets that
reading, the raw guesses, the text before your cursor, the app and your own words,
and writes the sentence you meant with punctuation. Without them, offline rules
fix casing and punctuation.
"""
import os
import re
import sys

MODEL = os.environ.get("LIPDICTATION_MODEL", "claude-opus-5-5")

SYSTEM = """You turn the output of a lip-reading model into the text the user meant. It is used for silent
dictation: the user mouthed a short piece of English without a sound, and it will be typed at their cursor.

Lip reading sees lip shapes, not sounds. Words that look alike on the lips get confused: p/b/m, f/v,
t/d/n/s/z/l, k/g/h, ch/j/sh, and the vowels blur together, so "meal" and "mail" or "pat" and "bat" look
identical. Short words are often dropped, added or swapped (a/the, in/and). You get:
- the best reading after a language model has weighed the alternatives,
- the lip reader's raw guesses, most likely first,
- what the user had already written before the cursor, the app they're in, and their own words (names, terms).

Write what the user most plausibly mouthed: it must make sense after the text before the cursor, and every word
you choose should look like what the lips showed. Prefer the user's own words where they fit. Do not add ideas,
answer questions, or rephrase beyond fixing misread words. Use sentence case and punctuation (a question mark for
questions), digits where natural, and continue the style of the text before the cursor. Reply with only the text."""


def available():
    return bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))


def basic(text, words=()):
    """Offline rules: sentence case, a capital I, your words as you write them, end punctuation."""
    text = re.sub(r"\s+", " ", text).strip().lower()
    if not text:
        return ""
    text = re.sub(r"\bi\b", "I", text)
    text = re.sub(r"\bi'(m|ll|ve|d)\b", lambda m: "I'" + m.group(1), text)
    for w in words:
        if w.strip():
            text = re.sub(rf"\b{re.escape(w.strip().lower())}\b", w.strip(), text)
    text = text[0].upper() + text[1:]
    if text[-1] not in ".?!":
        text += "?" if is_question(text) else "."
    return text


QUESTION_START = {"what", "why", "how", "when", "where", "who", "whom", "whose", "which", "can", "could",
                  "would", "should", "is", "are", "am", "was", "were", "do", "does", "did", "will", "shall",
                  "have", "has", "may", "might", "isn't", "aren't", "don't", "doesn't", "didn't", "won't",
                  "can't", "what's", "where's", "who's", "how's"}
OPENERS = {"hey", "hi", "hello", "oh", "so", "and", "but", "well", "okay", "ok", "um", "yo", "then", "now",
           "sorry", "please", "excuse", "me", "dear", "baby", "babe", "mate", "guys", "buddy", "honey"}


def is_question(text):
    """A question if it starts with a question word, after any greeting ("hey baby how are you")."""
    words = re.findall(r"[a-z']+", text.lower())
    for i, w in enumerate(words[:4]):
        if w in QUESTION_START:
            return i == 0 or all(x in OPENERS for x in words[:i])
        if w not in OPENERS:
            return False
    return False


class Cleaner:
    """mode: auto (Claude when a key is available), claude, or basic. api_key overrides the environment."""

    def __init__(self, mode="auto", api_key=None):
        has_key = bool(api_key) or available()
        self.mode = "claude" if mode in ("auto", "claude") and has_key else "basic"
        self.client = None
        if self.mode == "claude":
            import anthropic
            kwargs = {"api_key": api_key} if api_key else {}
            self.client = anthropic.Anthropic(timeout=10.0, max_retries=1, **kwargs)

    def __call__(self, guesses, recent=(), best=None, context="", app="", words=()):
        """guesses: raw readings, best first. best: the reading the context step chose."""
        if not guesses:
            return ""
        best = best or guesses[0]
        if self.mode != "claude":
            return basic(best, words)
        try:
            return self._claude(guesses, recent, best, context, app, words) or basic(best, words)
        except Exception as e:      # network, auth, rate limit: never lose the dictation
            print(f"  cleanup failed ({type(e).__name__}: {e}); using offline rules", file=sys.stderr)
            return basic(best, words)

    def _claude(self, guesses, recent, best, context, app, words):
        parts = [f"Best reading (after weighing context): {best.lower()}",
                 "Raw lip-reading guesses, most likely first:\n" + "\n".join(f"{i + 1}. {g.lower()}" for i, g in enumerate(guesses))]
        if context.strip():
            parts.append(f"Text before the cursor:\n<<<\n{context.strip()[-600:]}\n>>>")
        elif recent:
            parts.append("Recent dictations, oldest first:\n" + "\n".join(f"- {r}" for r in recent))
        if app:
            parts.append(f"App: {app}")
        if words:
            parts.append("The user's own words: " + ", ".join(words[:200]))
        prompt = "\n\n".join(parts)
        response = self.client.beta.messages.create(
            model=MODEL,
            max_tokens=1024,
            system=SYSTEM,
            output_config={"effort": "low"},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            messages=[{"role": "user", "content": prompt}],
        )
        if response.stop_reason == "refusal":
            return ""
        text = "".join(b.text for b in response.content if b.type == "text").strip()
        return text.strip('"“”')
