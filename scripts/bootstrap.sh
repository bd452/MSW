#!/usr/bin/env bash
set -euo pipefail

if [[ "${OSTYPE}" != "darwin"* ]]; then
  echo "[bootstrap] This script must be run on macOS to provision the WinRun host stack." >&2
  exit 1
fi

echo "[bootstrap] Installing brew dependencies"
brew bundle --file=- <<'BUNDLE'
brew 'cmake'
brew 'ninja'
brew 'glib'
brew 'pkg-config'
brew 'spice-protocol'
brew 'spice-gtk'
BUNDLE

mkdir -p "${HOME}/Library/Application Support/WinRun"
echo "[bootstrap] Ready to build WinRun components"
