"""Context: pick the sentence that makes sense, not just the one that looks right.

Lip reading confuses words that look alike on the lips ("homophenes": meal / mail,
pat / bat / mat). A language model knows that after "I want to eat a" comes a food,
not a car. This step combines the two, the way a speech recogniser combines its
acoustic model with a language model:

  score = lip evidence (beam-search score of the reading it came from)
        + weight × language-model log-probability of the sentence, given what you wrote before
        + a small bonus per word (language models otherwise prefer dropping words)
        − a cost for each word swapped for a look-alike (small if the lip shapes are identical,
          larger if they differ by one shape)

It starts from the lip reader's best readings. Then, like an LLM guessing the next word, one
pass of the language model over the sentence gives, at every position, how likely each
look-alike word would be there (from a 45,000-word lexicon, data/lexicon.tsv). Only the few
look-alikes it finds plausible are tried as whole sentences, and a swap is kept when the
whole sentence scores better. Your own words (names, jargon) join the lexicon too.
"""
import re
import time
from collections import defaultdict
from pathlib import Path


DATA = Path(__file__).parent / "data"
WORD = re.compile(r"[a-z]+(?:'[a-z]+)?")


class Lexicon:
    def __init__(self, path=DATA / "lexicon.tsv"):
        self.vis = {}                       # word -> viseme string
        self.zipf = {}                      # word -> frequency (Zipf scale, 1-8)
        self.by_vis = defaultdict(list)     # viseme string -> words, most common first
        for line in open(path):
            word, vis, z = line.rstrip("\n").split("\t")
            self.vis[word] = vis
            self.zipf[word] = float(z)
            self.by_vis[vis].append(word)
        self.deletions = defaultdict(set)   # for finding strings one lip shape apart
        for vis in self.by_vis:
            for k in self._deletions(vis):
                self.deletions[k].add(vis)

    @staticmethod
    def _deletions(v):
        return {v[:i] + v[i + 1:] for i in range(len(v))}

    def add(self, word, vis, zipf=5.0):
        """A word of yours: treated as common, so it can win."""
        word = word.lower()
        if word in self.vis:
            self.zipf[word] = max(self.zipf[word], zipf)
            return
        self.vis[word], self.zipf[word] = vis, zipf
        self.by_vis[vis].insert(0, word)
        for k in self._deletions(vis):
            self.deletions[k].add(vis)

    def neighbours(self, v):
        """Viseme strings one substitution, insertion or deletion away from v."""
        out = set(self.deletions.get(v, ()))                 # insertions
        for k in self._deletions(v):
            if k in self.by_vis:
                out.add(k)                                    # deletions
            out |= {u for u in self.deletions.get(k, ()) if len(u) == len(v)}   # substitutions
        out.discard(v)
        return out


class Corrector:
    def __init__(self, lm_dir, lexicon=None, device=None, lm_weight=0.5, vsr_weight=0.4,
                 same_cost=3.0, near_cost=6.0, rounds=2, per_word=12, keep=3, word_bonus=1.0):
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
        self.torch = torch
        self.device = device or ("mps" if torch.backends.mps.is_available() else "cpu")
        self.tok = AutoTokenizer.from_pretrained(lm_dir)
        dtype = torch.float16 if self.device != "cpu" else torch.float32
        self.lm = AutoModelForCausalLM.from_pretrained(lm_dir, dtype=dtype).to(self.device).eval()
        self.lex = lexicon or Lexicon()
        self.lm_weight, self.vsr_weight = lm_weight, vsr_weight
        self.same_cost, self.near_cost = same_cost, near_cost
        self.rounds, self.per_word, self.keep = rounds, per_word, keep
        self.word_bonus = word_bonus      # offsets the language model's taste for short sentences
        self.start = self.tok.bos_token or self.tok.eos_token or "\n"
        self.custom = set()
        self._alt_cache = {}
        self._tok_cache = {}
        self.correct([("HELLO HOW ARE YOU", 0.0)])     # warm up the GPU, so the first dictation isn't slow

    def set_words(self, words):
        """Your vocabulary: names and terms the lip reader should be able to produce."""
        self.custom = set()
        for w in words:
            for part in WORD.findall(w.lower()):
                vis = self.lex.vis.get(part) or _guess_visemes(part)
                if vis:
                    self.lex.add(part, vis)
                    self.custom.add(part)
        self._alt_cache.clear()

    # -- look-alikes ---------------------------------------------------------

    def alternatives(self, word):
        """[(look-alike, cost)] for a word, most common first."""
        if word in self._alt_cache:
            return self._alt_cache[word]
        v = self.lex.vis.get(word)
        out = []
        if v:
            for w in self.lex.by_vis[v]:
                if w != word and (self.lex.zipf[w] >= 3.0 or w in self.custom):
                    out.append((w, self.same_cost))
                if len(out) >= self.per_word:
                    break
            if len(v) >= 2:
                near = [w for u in self.lex.neighbours(v) for w in self.lex.by_vis[u][:4]
                        if self.lex.zipf[w] >= 3.5 or w in self.custom]
                near.sort(key=lambda w: -self.lex.zipf[w])
                out += [(w, self.near_cost) for w in near[:self.per_word]]
        self._alt_cache[word] = out
        return out

    # -- language model ------------------------------------------------------

    def _prefix(self, context):
        return self.tok(self.start + (context.strip() + " " if context.strip() else ""),
                        add_special_tokens=False).input_ids

    def _first_token(self, word, first):
        key = (word, first)
        if key not in self._tok_cache:
            w = "I" + word[1:] if word == "i" or word.startswith("i'") else word
            piece = w[:1].upper() + w[1:] if first else " " + w
            self._tok_cache[key] = self.tok(piece, add_special_tokens=False).input_ids[0]
        return self._tok_cache[key]

    def next_word_logprobs(self, words, context=""):
        """One pass: for each position, log P(first token of a word there | everything before it)."""
        torch = self.torch
        prefix = self._prefix(context)
        sentence = _sentence_case(" ".join(words))
        enc = self.tok(sentence, add_special_tokens=False, return_offsets_mapping=True)
        ids = torch.tensor([prefix + enc.input_ids], device=self.device)
        with torch.no_grad():
            logp = torch.log_softmax(self.lm(input_ids=ids).logits[0].float(), dim=-1)
        starts, c = [], 0
        for w in words:                               # character where each word starts
            starts.append(c)
            c += len(w) + 1
        rows = []
        for st in starts:
            j = next((k for k, (a, b) in enumerate(enc.offset_mapping) if b > st), len(enc.input_ids) - 1)
            rows.append(logp[len(prefix) + j - 1])    # the distribution that predicts that token
        return rows

    def lm_logprob(self, sentences, context=""):
        """Log-probability of each sentence following the context (natural log, summed over tokens)."""
        torch = self.torch
        prefix = self._prefix(context)
        seqs = [prefix + self.tok(s, add_special_tokens=False).input_ids for s in sentences]
        n = max(len(s) for s in seqs)
        pad = self.tok.pad_token_id if self.tok.pad_token_id is not None else 0
        ids = torch.full((len(seqs), n), pad, dtype=torch.long)
        mask = torch.zeros((len(seqs), n), dtype=torch.long)
        for i, s in enumerate(seqs):
            ids[i, :len(s)] = torch.tensor(s)
            mask[i, :len(s)] = 1
        ids, mask = ids.to(self.device), mask.to(self.device)
        with torch.no_grad():
            logits = self.lm(input_ids=ids, attention_mask=mask).logits.float()
        logp = torch.log_softmax(logits[:, :-1], dim=-1).gather(2, ids[:, 1:, None]).squeeze(2)
        out = []
        for i, s in enumerate(seqs):
            out.append(float(logp[i, len(prefix) - 1:len(s) - 1].sum()))
        return out

    # -- search --------------------------------------------------------------

    def correct(self, nbest, context=""):
        """nbest: [(TEXT, beam score)] from the lip reader, best first.

        Returns (text, info). text is lowercase without punctuation, like the input."""
        t0 = time.perf_counter()
        if not nbest:
            return "", {}
        top = nbest[0][1]
        cands = {}                                # sentence -> (vsr part, cost, words of origin)
        for text, score in nbest:
            words = text.lower().split()
            cands[" ".join(words)] = (self.vsr_weight * (score - top), 0.0, words)
        scored = self._score(cands, context)
        best = max(scored, key=scored.get)
        vsr_part, _, origin = cands[best]
        current = best.split()
        swaps = 0
        for _ in range(self.rounds):
            rows = self.next_word_logprobs(current, context)
            trial = {}
            for i, w in enumerate(origin):        # look-alikes of what the lips showed, never of a swap
                options = [(alt, cost) for alt, cost in self.alternatives(w) if alt != current[i]]
                if current[i] != w:
                    options.append((w, 0.0))
                if not options:
                    continue
                here = self.lm_weight * float(rows[i][self._first_token(current[i], i == 0)]) - self._cost(w, current[i])
                ranked = sorted(((self.lm_weight * float(rows[i][self._first_token(alt, i == 0)]) - cost, alt)
                                 for alt, cost in options), reverse=True)
                for value, alt in ranked[:self.keep]:
                    if value < here - 3.0:            # the model doesn't think it fits better: skip
                        break
                    words = current[:i] + [alt] + current[i + 1:]
                    key = " ".join(words)
                    if key not in scored:
                        trial[key] = (vsr_part, sum(self._cost(o, c) for o, c in zip(origin, words)), origin)
            if not trial:
                break
            new = self._score(trial, context)
            scored.update(new)
            cand = max(new, key=new.get)
            if new[cand] <= scored[" ".join(current)]:
                break
            current = cand.split()
            swaps += 1
        text = " ".join(current)
        return text, {"seconds": time.perf_counter() - t0, "swaps": swaps, "candidates": len(scored),
                      "reading": " ".join(nbest[0][0].lower().split())}

    def _cost(self, original, word):
        if original == word:
            return 0.0
        return self.same_cost if self.lex.vis.get(original) == self.lex.vis.get(word) else self.near_cost

    def _score(self, cands, context):
        keys = list(cands)
        out = {}
        for i in range(0, len(keys), 64):
            batch = keys[i:i + 64]
            lps = self.lm_logprob([_sentence_case(k) for k in batch], context)
            for k, lp in zip(batch, lps):
                vsr_part, cost, _ = cands[k]
                out[k] = vsr_part + self.lm_weight * lp - cost + self.word_bonus * len(k.split())
        return out


def _sentence_case(text):
    text = re.sub(r"\bi\b", "I", text)
    text = re.sub(r"\bi'", "I'", text)
    return text[:1].upper() + text[1:]


_LETTERS = [("ch", "S"), ("sh", "S"), ("th", "T"), ("ph", "F"), ("ck", "K"), ("qu", "KW"), ("ee", "E"),
            ("oo", "O")]
_LETTER = {"p": "P", "b": "P", "m": "P", "f": "F", "v": "F", "t": "D", "d": "D", "n": "D", "s": "D",
           "z": "D", "l": "D", "j": "S", "k": "K", "g": "K", "c": "K", "h": "K", "y": "K", "q": "K",
           "x": "KD", "r": "R", "w": "W", "a": "A", "u": "A", "e": "E", "i": "E", "o": "O"}


def _guess_visemes(word):
    """Rough lip shapes for a word not in the lexicon (a name), from its spelling."""
    out, i = [], 0
    while i < len(word):
        for pair, v in _LETTERS:
            if word.startswith(pair, i):
                out.append(v)
                i += 2
                break
        else:
            out.append(_LETTER.get(word[i], ""))
            i += 1
    s = "".join(out)
    return re.sub(r"([^AEO])\1+", r"\1", s)
