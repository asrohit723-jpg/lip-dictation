# Lip Dictation

**Type by moving your lips.** Hold a key, silently mouth what you want to write, let go, and the
text appears wherever your cursor is. It works like Wispr Flow without the voice: the camera reads
your lips. No microphone, no sound. English only, on Apple Silicon Macs.

```
hold Right Option ─► camera ─► face tracking ─► 96×96 mouth crops at 25 fps
                                                        │
  text at your cursor ◄── cleanup (Claude or rules) ◄── lip-reading model on the Apple GPU
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
   - **Lip reader:** a one-time download of about 2 GB: a private Python with PyTorch and MediaPipe,
     and the 1.2 GB lip-reading model. Every model file is checked against its SHA-256.
   - **Try it:** mouth a test sentence and see what it reads.

Needs macOS 14 or later on Apple Silicon, and about 2.5 GB of disk.

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
paste or copy-only, sounds, camera choice and preview, launch at login, Claude cleanup and the
search width (speed against accuracy). **History** keeps everything you've dictated on this Mac,
searchable.

## Claude cleanup

Lip reading can't tell apart sounds that look the same on the lips (p/b/m, f/v, t/d/n), so the raw
reading is uppercase, unpunctuated and sometimes wrong. Add an Anthropic API key in **Settings ›
Cleanup** and the lip reader's five best guesses plus your last few dictations go to Claude
(`claude-opus-5-5`, low effort), which picks the sentence you meant and fixes punctuation and
look-alike words. Only that text is sent, never video. The key is stored in your keychain. Without
a key, offline rules fix capitals and punctuation.

## Privacy

- The camera runs only while you hold the key (and for a minute after, so the next dictation starts
  instantly), unless you choose to keep it on.
- Video is processed on your Mac and never saved or uploaded.
- With Claude cleanup on, the lip reader's text guesses go to the Anthropic API. Nothing else leaves
  your Mac.

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
([.github/workflows/release.yml](.github/workflows/release.yml)). The app checks GitHub every few
hours, and Settings › About has **Check now**. **Update now** swaps the app in place and relaunches.
Every release is signed with the same certificate, so macOS keeps the Camera and Accessibility
permissions, and the app refuses any download not signed with it. The lip reader stays installed;
if an update changes its libraries, they are refreshed in the background.

## How it's built

| Part | Where |
|---|---|
| Mac app (Swift, SwiftUI): menu bar, the pill, setup, Settings, History, camera, hold key, paste, updates | [mac-app/](mac-app/) |
| Lip-reading engine (Python), which the app runs as a child process and streams grayscale frames to | [lipdictation/engine.py](lipdictation/engine.py) |
| Face tracking and mouth crops (MediaPipe, aligned to the model's training mean face) | [lipdictation/face.py](lipdictation/face.py) |
| The model and beam search with a language model | [lipdictation/vsr.py](lipdictation/vsr.py), [espnet/](espnet/) |
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
