#!/bin/zsh
# Double-click in Finder to start lip dictation in Terminal.
cd "$(dirname "$0")"
exec .venv/bin/python -m lipdictation "$@"
