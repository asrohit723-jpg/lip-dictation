#!/bin/zsh
# Downloads the pinned uv into build/uv-aarch64-apple-darwin/uv and checks its SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
UV_VERSION=0.13.1
UV_SHA256=cfe454573412ff7380d15fc7dae5997ab53ffce72fce0a78e91ddbc84001acd2
mkdir -p build
TGZ="build/uv-$UV_VERSION.tar.gz"
if [ ! -s "$TGZ" ]; then
  curl -fsSL -o "$TGZ.part" "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz"
  mv "$TGZ.part" "$TGZ"
fi
echo "$UV_SHA256  $TGZ" | shasum -a 256 -c - >/dev/null || { echo "uv checksum mismatch"; rm -f "$TGZ"; exit 1; }
tar -xzf "$TGZ" -C build
echo "$PWD/build/uv-aarch64-apple-darwin/uv"
