"""Turn the lip reader's ranked guesses into the sentence you meant.

Lip reading can't tell apart sounds that look the same (p/b/m, f/v, t/d/n), so
the raw guesses are uppercase, unpunctuated and sometimes wrong in places. With
Claude credentials available, Claude picks and repairs the sentence using your
recent dictations as context. Without them, simple offline rules fix casing and
punctuation.
"""
import os
import re

MODEL = os.environ.get("LIPDICTATION_MODEL", "claude-opus-5-5")

SYSTEM = """You repair the output of a lip-reading model used for silent dictation.
The user mouthed one short piece of English without making a sound. The model gives its top guesses,
uppercase and without punctuation. Lip reading confuses words that look alike on the lips
(p/b/m, f/v, t/d/n, k/g, s/z, ch/j/sh) and sometimes drops or adds short words.

Pick the guess the user most likely meant, repairing look-alike words where the sentence clearly needs it,
using the recent dictations for context. Do not add ideas, answer questions, or rephrase.
Write normal sentence case with punctuation, digits for numbers where natural, and no surrounding quotes.
Reply with only the final text."""


def available():
    return bool(os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN"))


def basic(text):
    """Offline rules: sentence case, a capital I, end punctuation."""
    text = re.sub(r"\s+", " ", text).strip().lower()
    if not text:
        return ""
    text = re.sub(r"\bi\b", "I", text)
    text = re.sub(r"\bi'(m|ll|ve|d)\b", lambda m: "I'" + m.group(1), text)
    text = text[0].upper() + text[1:]
    if text[-1] not in ".?!":
        question = text.split(" ", 1)[0].lower() in {
            "what", "why", "how", "when", "where", "who", "which", "can", "could", "would",
            "should", "is", "are", "do", "does", "did", "will", "shall", "have", "has"}
        text += "?" if question else "."
    return text


class Cleaner:
    def __init__(self, mode="auto"):
        self.mode = "claude" if mode == "auto" and available() else ("basic" if mode == "auto" else mode)
        self.client = None
        if self.mode == "claude":
            import anthropic
            self.client = anthropic.Anthropic(timeout=10.0, max_retries=1)

    def __call__(self, guesses, recent=()):
        if not guesses:
            return ""
        if self.mode != "claude":
            return basic(guesses[0])
        try:
            return self._claude(guesses, recent) or basic(guesses[0])
        except Exception as e:      # network, auth, rate limit: never lose the dictation
            print(f"  cleanup failed ({type(e).__name__}: {e}); using offline rules")
            return basic(guesses[0])

    def _claude(self, guesses, recent):
        lines = [f"{i + 1}. {g}" for i, g in enumerate(guesses)]
        prompt = "Lip-reading guesses, most likely first:\n" + "\n".join(lines)
        if recent:
            prompt += "\n\nRecent dictations, oldest first:\n" + "\n".join(f"- {r}" for r in recent)
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
