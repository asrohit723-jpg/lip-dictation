# Lip Dictation

Silent dictation for macOS. Hold a key, **mouth** the words without making a sound, let go, and
the text is pasted at your cursor in whatever app you're in. It works like Wispr Flow, except
it reads your lips through the camera instead of listening to your voice. English only.
Everything except the optional Claude cleanup runs on the Mac.

```
hold Right Option ─► camera ─► face landmarks (live) ─► 96×96 mouth crops at 25 fps
                                                              │
     paste at cursor ◄── cleanup (Claude or rules) ◄── beam search + LM ◄── lip-reading encoder (Apple GPU)
```

## Set up

Needs an Apple Silicon Mac, Python 3.11 (`brew install python@3.11`) and about 2.5 GB of disk.

```bash
cd ~/lip-dictation && ./scripts/setup.sh
```

That creates `.venv`, installs the dependencies and downloads the model weights (about 1.2 GB)
into `models/`.

## Start it

Run it from macOS **Terminal** (not from inside Claude), or double-click **Lip Dictation.command**:

```bash
~/lip-dictation/.venv/bin/lip-dictation
```

The first time, give the Terminal app these permissions under System Settings › Privacy & Security,
then quit and reopen Terminal:

- **Camera**, to see your lips. The first run asks; if it then says the camera did not open, run it again.
- **Input Monitoring**, to notice the hold-to-talk key.
- **Accessibility**, to paste. Without it the text is only copied to the clipboard.

## Use it

| Do this | To |
|---|---|
| Hold **Right Option**, mouth the words, release | dictate |
| **Esc** while holding | cancel |
| **Ctrl+C** in Terminal | quit |

You hear a *tink* when it starts recording and a *pop* when it starts reading. Keep your face
towards the camera with your mouth fully in view and evenly lit. Mouth the words clearly and at
a normal pace: silent mouthing is usually smaller than speech, and the model was trained on people
speaking aloud, so exaggerate a little. Pause briefly before you let go, because it needs the
frames after your last word.

The camera turns on with your first dictation and turns off after a minute without one, so
back-to-back dictations start straight away.

Options:

```
--key {right_option,left_option,right_command,right_control,fn}   hold-to-talk key
--camera N            camera index (0 is usually the built-in camera), or a video file
--cleanup {auto,claude,basic}
--beam N              beam size (default 10); higher is slower, slightly more accurate
--copy-only           copy instead of pasting
```

Lip-read a video file instead of the camera:

```bash
.venv/bin/lip-dictation file talk.mp4 --start 10 --end 18
```

## Cleanup with Claude (recommended)

Lip reading can't tell apart sounds that look the same on the lips (p/b/m, f/v, t/d/n), so the
raw output is uppercase, unpunctuated and sometimes wrong. With an Anthropic API key, the five
best guesses and your last few dictations go to Claude (`claude-opus-5-5`, low effort), which
picks the sentence you meant and fixes casing, punctuation and look-alike words:

```bash
export ANTHROPIC_API_KEY=...        # e.g. in ~/.zshrc
```

Without a key it uses offline rules (sentence case, "I", end punctuation). Set
`LIPDICTATION_MODEL` to use a different Claude model. Requests use server-side refusal fallback
(`fallbacks: "default"`), so a declined request is retried on another model rather than lost.

## How good is it?

The model is Auto-AVSR's visual-only speech recogniser trained on LRS3 (TED talks), with
19.1% of words wrong on that benchmark. On news footage it can be word-perfect, for example:

| Said | Read |
|---|---|
| Born in New York City, and raised mostly in Chicago, Nancy Davis graduated from Smith College in 1943. | BORN IN NEW YORK CITY AND RAISED MOSTLY IN CHICAGO NANCY DAVIS GRADUATED FROM SMITH COLLEGE IN NINETEEN FORTY THREE |

Expect more errors on your own silent mouthing. Names and rare words are the hardest. From
release to text took about 1.5 seconds for a 6-second sentence and 3 seconds for an 8-second one
on an M4 MacBook Air, plus about a second when Claude cleanup is on.

## Development

```bash
./scripts/download-models.sh --samples     # adds a public-domain test clip
.venv/bin/python -m pytest -q tests
```

Code map: `lipdictation/face.py` (landmarks → aligned mouth crops), `vsr.py` (the model and beam
search), `camera.py` (capture with live tracking), `cleanup.py`, `macos.py` (key, paste, sounds),
`main.py` (wiring and CLI). `espnet/` is the model code from the authors' repository; see
[NOTICE](NOTICE) for licences. The LRS3-trained weights are for research and private study only.
