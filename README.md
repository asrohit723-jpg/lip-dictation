# Lip Dictation

**Type by moving your lips.** Hold a key, silently mouth what you want to write, let go, and the
text appears wherever your cursor is. It works like Wispr Flow without the voice: the camera reads
your lips. No microphone, no sound. English only, on Apple Silicon Macs.

```
hold Right Option ─► camera ─► face tracking ─► 96×96 mouth crops at 25 fps ─► lip-reading model (Apple GPU)
                                                                                      │ its 10 best readings
 text at your cursor ◄── cleanup (Claude or rules) ◄── context: on-device language model + look-alike words
                                                        (uses the text before your cursor and your own words)
```

## Install

1. Download `LipDictation-<version>.zip` from the
   [latest release](https://github.com/asrohit723-jpg/lip-dictation/releases/latest), unzip it and
   move **Lip Dictation** to Applications.
2. Open it. The app is signed with its own certificate rather than an Apple developer ID, so the
   first time macOS says it can't verify it. Click **Done**, then go to System Settings › Privacy &
   Security and click **Open Anyway** next to Lip Dictation.
3. Setup walks you through the rest:
   - **Permissions:** Camera (to see your lips) and Accessibility (to notice the key and type for you).
   - **Lip reader:** a one-time download of about 3 GB: a private Python with PyTorch and MediaPipe,
     the 1.2 GB lip-reading model and the 0.7 GB language model. Every model file is checked against its SHA-256.
   - **Try it:** mouth a test sentence and see what it reads.

Needs macOS 14 or later on Apple Silicon, and about 3.5 GB of disk.

## Use it

| Do this | To |
|---|---|
| Hold **Right Option**, mouth the words, let go | dictate into the app you're using |
| **Esc** while holding | cancel |
| Menu bar icon | last dictation, History, Settings |

While you hold the key, a small pill at the bottom of the screen shows your face, so you can keep
your mouth in view. It turns orange if it can't see your mouth. You hear a *tink* when it starts
and a *pop* when it starts reading.

Tips for good results:

- Face the camera, with your whole mouth visible and lit from the front.
- Mouth the words clearly, a little more than when speaking, and pause before you let go.
- Short, everyday sentences work best. Names and rare words are the hardest to read from lips.

**Settings** has the hold key (Right Option, Right Command, Right Control, Left Option or Fn),
paste or copy-only, sounds, camera choice and preview, launch at login, context and your words,
Claude cleanup and the search width (speed against accuracy). **History** keeps everything you've dictated on this Mac,
searchable.

## Context: picking words that make sense

Lips show shapes, not sounds. "Meal" and "mail" look identical, and so do "pat", "bat" and "mat". So,
like a speech recogniser pairing its acoustic model with a language model, Lip Dictation adds a
language model that runs on your Mac (SmolLM2-360M):

1. The lip reader gives its 10 best readings, each with a score for how well it matches your lips.
2. A lexicon of 45,000 common words, each written as its sequence of lip shapes (from the CMU
   Pronouncing Dictionary), lists every word's look-alikes: identical shapes, or one shape apart.
3. One pass of the language model over the sentence gives, at each position, how likely each look-alike
   would be there, given the words before it and the text before your cursor. That's the
   "LLM guessing the next word" step: after "I want to eat a", food scores high and "car" low.
4. The few look-alikes it finds plausible are tried as whole sentences. The winner is scored on the
   lip evidence, the language model, a cost per swapped word (small for identical lip shapes) and
   a small bonus per word.

**Your words** (Settings › Accuracy) adds names and terms to the lexicon, so a name you use can win
when the lips fit it. The step takes about 0.2 seconds for a short sentence.

On subtitled news footage (49 sentences, `scripts/eval_context.py`), the word error rate went from
20.5% with the lip reader alone to 18.2% with the context step (19.3% without the previous sentence as context). On real dictation, which
has less context than a news speech, expect the gain to vary.

### What Wispr Flow does, and what we borrowed

Wispr Flow's own write-ups describe dictation as a context problem rather than a pure recognition
problem: speech recognition conditioned on the app you're in, the text around your cursor, your
history and your personal dictionary, followed by a fine-tuned LLM that formats the text, all within
about 700 ms. Lip Dictation borrows the same ideas, adapted for lips: the text before your cursor and
the app name, your own words, your recent dictations, an on-device language model that resolves
look-alike words, and an optional Claude pass for formatting and harder repairs.

## Claude cleanup

Lip reading can't tell apart sounds that look the same on the lips (p/b/m, f/v, t/d/n), so the raw
reading is uppercase, unpunctuated and sometimes wrong. Add an Anthropic API key in **Settings ›
Accuracy** and the context step's reading, the lip reader's five best guesses, the text before your
cursor, the app name and your words go to Claude (`claude-opus-5-5`, low effort), which writes the
sentence you meant with punctuation. Only that text is sent, never video. The key is stored in your keychain. Without
a key, offline rules fix capitals and punctuation.

## Privacy

- The camera runs only while you hold the key (and for a minute after, so the next dictation starts
  instantly), unless you choose to keep it on.
- Video is processed on your Mac and never saved or uploaded.
- The text before your cursor (never from password fields) is read when you start dictating and
  stays on your Mac for the on-device language model. Turn it off in Settings › Accuracy.
- With Claude cleanup on, the text guesses, that text, the app name and your words go to the
  Anthropic API. Nothing else leaves your Mac.

## How good is it?

The model is Auto-AVSR's visual-only speech recogniser trained on LRS3 (TED talks): 19.1% of
words wrong on that benchmark. On clear news footage it can be word-perfect:

| Said | Read |
|---|---|
| Born in New York City, and raised mostly in Chicago, Nancy Davis graduated from Smith College in 1943. | BORN IN NEW YORK CITY AND RAISED MOSTLY IN CHICAGO NANCY DAVIS GRADUATED FROM SMITH COLLEGE IN NINETEEN FORTY THREE |

Silent mouthing is harder than filmed speech, because people move their lips less when they make no
sound, so expect more mistakes on your own dictation. Claude cleanup helps the most. On an M4
MacBook Air, text appears about 1.5–2.5 seconds after you let go of an 8-second sentence.

## Updates

Every push to `main` builds, signs and publishes a release
([.github/workflows/release.yml](.github/workflows/release.yml)). You never reinstall: when a new
version is out, an **Update** button appears at the top of the menu (and in the right-click menu on
the menu bar icon and Settings › About). One click downloads it, checks its signature, swaps it in and
reopens the app. The bottom of the menu always shows the version and **Check for updates**.
Every release is signed with the same certificate, so macOS keeps the Camera and Accessibility
permissions, and the app refuses any download not signed with it. The lip reader stays installed; if an
update needs new libraries or models, they download in the background while dictation keeps working.

## How it's built

| Part | Where |
|---|---|
| Mac app (Swift, SwiftUI): menu bar, the pill, setup, Settings, History, camera, hold key, paste, updates | [mac-app/](mac-app/) |
| Lip-reading engine (Python), which the app runs as a child process and streams grayscale frames to | [lipdictation/engine.py](lipdictation/engine.py) |
| Face tracking and mouth crops (MediaPipe, aligned to the model's training mean face) | [lipdictation/face.py](lipdictation/face.py) |
| The model and beam search with a language model | [lipdictation/vsr.py](lipdictation/vsr.py), [espnet/](espnet/) |
| Context: look-alike words and the on-device language model | [lipdictation/context.py](lipdictation/context.py), [lipdictation/visemes.py](lipdictation/visemes.py) |
| Cleanup | [lipdictation/cleanup.py](lipdictation/cleanup.py) |

The app owns the camera, so macOS permissions belong to the app. On first launch it uses a bundled,
pinned [uv](https://github.com/astral-sh/uv) to fetch Python 3.11 and the engine's libraries into
`~/Library/Application Support/Lip Dictation/`, and downloads the model weights there. The log is
`~/Library/Logs/Lip Dictation.log`.

### Develop

```bash
# The app
mac-app/build.sh                    # builds and installs an ad-hoc signed ~/Applications/Lip Dictation.app
mac-app/build/Lip\ Dictation.app/Contents/MacOS/LipDictation --install          # first-run setup, headless
mac-app/build/Lip\ Dictation.app/Contents/MacOS/LipDictation --dictate-file clip.mov --start 20 --end 28
mac-app/build/Lip\ Dictation.app/Contents/MacOS/LipDictation --snapshot /tmp/shots   # renders every screen

# The engine on its own, from the terminal
./scripts/setup.sh --samples        # venv, models and a public-domain test clip
.venv/bin/lip-dictation file samples/2016-03-12.mov --start 20 --end 28
.venv/bin/python -m pytest -q tests

# Measure accuracy on subtitled clips (samples/*.srt next to each video)
.venv/bin/python scripts/eval_cache.py samples/2016-03-12.mov samples/2017-01-07.mov
.venv/bin/python scripts/eval_context.py models/text-lm
```

`--dictate-file` plays a video through the same path as the camera, so the whole app can be tested
without one. Local builds are ad-hoc signed, so installing one makes macOS ask for permissions again
until the next release.

**Signing certificate:** made once with `mac-app/scripts/make-signing-cert.sh`. The private key lives
in `~/.lip-dictation-signing/` and in the repo secrets `MAC_P12` and `MAC_P12_PASSWORD`. Keep that
folder: with a new certificate, the next update would need permissions granted again, and the
updater (which checks the certificate's fingerprint) would refuse it.

## Licences

`espnet/` and the model come from
[Visual Speech Recognition for Multiple Languages](https://github.com/mpc001/Visual_Speech_Recognition_for_Multiple_Languages)
by Pingchuan Ma et al.; see [NOTICE](NOTICE). The LRS3-trained model weights are for research and
private study only, not for commercial use.
