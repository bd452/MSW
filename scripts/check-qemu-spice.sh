#!/usr/bin/env bash
set -euo pipefail

QEMU_BIN="${1:-}"

if [[ -z "${QEMU_BIN}" ]]; then
  if [[ -n "${WINRUN_QEMU_BINARY:-}" && -x "${WINRUN_QEMU_BINARY}" ]]; then
    QEMU_BIN="${WINRUN_QEMU_BINARY}"
  elif [[ -n "${WINRUN_QEMU_PREFIX:-}" && -x "${WINRUN_QEMU_PREFIX}/bin/qemu-system-aarch64" ]]; then
    QEMU_BIN="${WINRUN_QEMU_PREFIX}/bin/qemu-system-aarch64"
  elif command -v qemu-system-aarch64 >/dev/null 2>&1; then
    QEMU_BIN="$(command -v qemu-system-aarch64)"
  else
    echo "❌ qemu-system-aarch64 not found" >&2
    exit 1
  fi
fi

if [[ ! -x "${QEMU_BIN}" ]]; then
  echo "❌ QEMU binary is not executable: ${QEMU_BIN}" >&2
  exit 1
fi

OUTPUT="$("${QEMU_BIN}" -help 2>&1 || true)"
if [[ "${OUTPUT}" != *"-spice "* && "${OUTPUT}" != *"-spice"* ]]; then
  echo "❌ QEMU lacks SPICE support: ${QEMU_BIN}" >&2
  echo "   Need a SPICE-enabled qemu-system-aarch64 build for WinRun runtime." >&2
  exit 2
fi

echo "✅ QEMU SPICE support detected: ${QEMU_BIN}"
