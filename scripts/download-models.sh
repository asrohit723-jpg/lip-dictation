#!/bin/zsh
# Downloads the model weights (~1.2 GB) into models/. Safe to re-run.
#  - Auto-AVSR visual speech recognition, LRS3, 19.1% WER, and its subword language model,
#    from the authors' links (github.com/mpc001/Visual_Speech_Recognition_for_Multiple_Languages)
#  - MediaPipe face landmarker
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p models && cd models
GDOWN=../.venv/bin/gdown
[ -x "$GDOWN" ] || ../.venv/bin/pip install -q gdown

if [ ! -s vsr/model.pth ]; then
  $GDOWN 1t8RHhzDTTvOQkLQhmK1LZGnXRRXOXGi6 -O vsr.zip
  unzip -q -o vsr.zip && rm vsr.zip && rm -rf vsr && mv LRS3_V_WER19.1 vsr
fi
if [ ! -s lm/model.pth ]; then
  $GDOWN 1g31HGxJnnOwYl17b70ObFQZ1TSnPvRQv -O lm.zip
  unzip -q -o lm.zip && rm lm.zip && rm -rf lm && mv lm_en_subword lm
fi
[ -s face_landmarker.task ] || curl -fsSL -o face_landmarker.task \
  https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
ls -la vsr lm face_landmarker.task

if [[ "${1:-}" == "--samples" ]]; then
  # Public-domain test clip (White House weekly address, Wikimedia Commons), used by tests/
  mkdir -p ../samples
  [ -s ../samples/2016-03-12.mov ] || curl -fsSL -o ../samples/2016-03-12.mov \
    "https://upload.wikimedia.org/wikipedia/commons/transcoded/c/ce/2016-03-12_President_Obama%27s_Weekly_Address.webm/2016-03-12_President_Obama%27s_Weekly_Address.webm.360p.mpeg4.mov"
fi
