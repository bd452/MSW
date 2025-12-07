#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_ROOT}/.." && pwd)"

pushd "${REPO_ROOT}/host" >/dev/null
swift build
popd >/dev/null

if command -v dotnet >/dev/null 2>&1; then
  pushd "${REPO_ROOT}/guest" >/dev/null
  dotnet build WinRunAgent.sln
  popd >/dev/null
else
  echo "[build] dotnet not found; skipping guest build" >&2
fi
