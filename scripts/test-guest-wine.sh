#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${WINE_TEST_PROJECT:-${REPO_ROOT}/guest/WinRunAgent.Tests/WinRunAgent.Tests.csproj}"
CONFIGURATION="${WINE_TEST_CONFIGURATION:-Debug}"
WINE_DOTNET_EXE="${WINE_DOTNET_EXE:-${HOME}/.dotnet-windows/dotnet.exe}"

if command -v wine64 >/dev/null 2>&1; then
  WINE_BIN="wine64"
elif command -v wine >/dev/null 2>&1; then
  WINE_BIN="wine"
else
  echo "❌ Wine is required for test-guest-wine." >&2
  echo "   Install Wine, then re-run this command." >&2
  exit 1
fi

if ! command -v winepath >/dev/null 2>&1; then
  echo "❌ winepath is required but was not found." >&2
  echo "   Ensure Wine is installed with winepath available." >&2
  exit 1
fi

if [[ ! -f "${PROJECT_PATH}" ]]; then
  echo "❌ Test project not found: ${PROJECT_PATH}" >&2
  exit 1
fi

if [[ ! -f "${WINE_DOTNET_EXE}" ]]; then
  echo "❌ Windows dotnet.exe not found at: ${WINE_DOTNET_EXE}" >&2
  echo "   Set WINE_DOTNET_EXE to your Windows dotnet.exe path." >&2
  echo "   Example: WINE_DOTNET_EXE=\"${HOME}/.dotnet-windows/dotnet.exe\" make test-guest-wine" >&2
  exit 1
fi

PROJECT_WIN_PATH="$(winepath -w "${PROJECT_PATH}")"
DOTNET_WIN_PATH="$(winepath -w "${WINE_DOTNET_EXE}")"

export WINEDEBUG="${WINEDEBUG:--all}"

echo "🔧 Wine binary: ${WINE_BIN}"
echo "🔧 Windows dotnet.exe: ${WINE_DOTNET_EXE}"
echo "🧪 Running Windows guest tests under Wine..."

"${WINE_BIN}" "${DOTNET_WIN_PATH}" test "${PROJECT_WIN_PATH}" -c "${CONFIGURATION}" --nologo "$@"
