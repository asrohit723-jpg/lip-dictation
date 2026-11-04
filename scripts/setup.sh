#!/bin/zsh
# One-time setup: Python 3.11 virtualenv, dependencies, model weights.
set -euo pipefail
cd "$(dirname "$0")/.."
PY=$(command -v python3.11 || command -v python3.12 || true)
[ -n "$PY" ] || { echo "Needs Python 3.11 or 3.12: brew install python@3.11"; exit 1; }
[ -d .venv ] || "$PY" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -e . gdown pytest
./scripts/download-models.sh "$@"
echo "Done. Start it with: .venv/bin/lip-dictation   (from macOS Terminal)"
