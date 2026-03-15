#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${WINE_TEST_PROJECT:-${REPO_ROOT}/guest/WinRunAgent.Tests/WinRunAgent.Tests.csproj}"
CONFIGURATION="${WINE_TEST_CONFIGURATION:-Debug}"
WINE_DOTNET_EXE="${WINE_DOTNET_EXE:-${HOME}/.dotnet-windows/dotnet.exe}"
LINUX_DOTNET="${LINUX_DOTNET:-}"
WINEPREFIX="${WINEPREFIX:-${HOME}/.wine-winrun}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $(basename "$0") [dotnet test args...]

Run guest tests under Wine using a Windows dotnet.exe.

Environment variables:
  WINE_TEST_PROJECT        Test project path (default: ${PROJECT_PATH})
  WINE_TEST_CONFIGURATION  Build configuration (default: ${CONFIGURATION})
  WINE_DOTNET_EXE          Windows dotnet.exe path (default: ${WINE_DOTNET_EXE})
  LINUX_DOTNET             Linux dotnet path used for restore priming
  WINEPREFIX               Wine prefix (default: ${WINEPREFIX})
  WINEDEBUG                Wine debug level (default: -all)
  WINE_SKIP_NATIVE_RESTORE Set to 1 to skip Linux restore priming

Setup helper:
  make setup-wine-tests
EOF
  exit 0
fi

run_wine_command() {
  local cmd=("$@")
  local quoted=""
  local arg

  if command -v script >/dev/null 2>&1; then
    for arg in "${cmd[@]}"; do
      quoted+=" $(printf '%q' "${arg}")"
    done
    quoted="${quoted# }"
    script -qec "${quoted}" /dev/null
  else
    "${cmd[@]}"
  fi
}

resolve_linux_dotnet() {
  if [[ -n "${LINUX_DOTNET}" ]]; then
    echo "${LINUX_DOTNET}"
  elif command -v dotnet >/dev/null 2>&1; then
    command -v dotnet
  elif [[ -x "${HOME}/.dotnet/dotnet" ]]; then
    echo "${HOME}/.dotnet/dotnet"
  else
    echo ""
  fi
}

if command -v wine64 >/dev/null 2>&1; then
  WINE_BIN="wine64"
elif command -v wine >/dev/null 2>&1; then
  WINE_BIN="wine"
else
  echo "❌ Wine is required for test-guest-wine." >&2
  echo "   Run: make setup-wine-tests" >&2
  exit 1
fi

if [[ ! -f "${PROJECT_PATH}" ]]; then
  echo "❌ Test project not found: ${PROJECT_PATH}" >&2
  exit 1
fi

if [[ ! -f "${WINE_DOTNET_EXE}" ]]; then
  echo "❌ Windows dotnet.exe not found at: ${WINE_DOTNET_EXE}" >&2
  echo "   Run: make setup-wine-tests" >&2
  echo "   Or set WINE_DOTNET_EXE to an existing Windows dotnet.exe path." >&2
  exit 1
fi

PROJECT_PATH="$(realpath "${PROJECT_PATH}")"
WINE_DOTNET_EXE="$(realpath "${WINE_DOTNET_EXE}")"
PROJECT_WIN_PATH="Z:${PROJECT_PATH}"
LINUX_DOTNET_CMD="$(resolve_linux_dotnet)"
HAS_NO_RESTORE=0

for arg in "$@"; do
  if [[ "${arg}" == "--no-restore" ]]; then
    HAS_NO_RESTORE=1
    break
  fi
done

export WINEPREFIX
export WINEDEBUG="${WINEDEBUG:--all}"

if [[ ! -d "${WINEPREFIX}" ]]; then
  WINEDEBUG=-all wineboot --init >/dev/null 2>&1 || true
fi

echo "🔧 Wine binary: ${WINE_BIN}"
echo "🔧 Windows dotnet.exe: ${WINE_DOTNET_EXE}"
echo "🔧 WINEPREFIX: ${WINEPREFIX}"
echo "🧪 Running Windows guest tests under Wine..."

if [[ "${WINE_SKIP_NATIVE_RESTORE:-0}" != "1" ]]; then
  if [[ -n "${LINUX_DOTNET_CMD}" ]]; then
    echo "🔧 Priming restore with Linux dotnet (${LINUX_DOTNET_CMD})..."
    "${LINUX_DOTNET_CMD}" restore "${PROJECT_PATH}" --nologo
  else
    echo "⚠️  Linux dotnet not found; Wine restore may fail due signature validation." >&2
  fi
fi

WINE_TEST_ARGS=(test "${PROJECT_WIN_PATH}" -c "${CONFIGURATION}" --nologo)
if [[ "${HAS_NO_RESTORE}" -eq 0 ]]; then
  WINE_TEST_ARGS+=(--no-restore)
fi
WINE_TEST_ARGS+=("$@")

run_wine_command "${WINE_BIN}" "${WINE_DOTNET_EXE}" "${WINE_TEST_ARGS[@]}"
