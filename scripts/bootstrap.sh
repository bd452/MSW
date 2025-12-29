#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_LABEL="com.winrun.daemon"
PLIST_SRC="${REPO_ROOT}/infrastructure/launchd/com.winrun.daemon.plist"
PLIST_DST="/Library/LaunchDaemons/com.winrun.daemon.plist"
BINARY_DST="/usr/local/bin/winrund"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Bootstrap the WinRun development environment on macOS.

Options:
  --install-daemon    Install/upgrade the LaunchDaemon after bootstrapping
  --uninstall-daemon  Uninstall the LaunchDaemon and exit
  -h, --help          Show this help message

Examples:
  $(basename "$0")                 # Bootstrap only (install deps, create dirs)
  $(basename "$0") --install-daemon  # Bootstrap + install daemon (requires sudo)
EOF
}

# Check if daemon is currently loaded
daemon_is_loaded() {
  sudo launchctl print "system/${DAEMON_LABEL}" &>/dev/null
}

# Unload the daemon if running
unload_daemon() {
  if daemon_is_loaded; then
    echo "[bootstrap] Unloading existing daemon..."
    sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
    # Give it a moment to fully unload
    sleep 1
  fi
}

# Install or upgrade the LaunchDaemon
install_daemon() {
  # Determine binary source - prefer release build, fall back to debug
  local binary_src=""
  if [[ -f "${REPO_ROOT}/host/.build/release/winrund" ]]; then
    binary_src="${REPO_ROOT}/host/.build/release/winrund"
  elif [[ -f "${REPO_ROOT}/host/.build/debug/winrund" ]]; then
    binary_src="${REPO_ROOT}/host/.build/debug/winrund"
    echo "[bootstrap] Warning: Using debug build. For production, build with 'swift build -c release'"
  fi

  echo "[bootstrap] Installing LaunchDaemon..."
  echo "[bootstrap] This requires sudo access."

  # Unload if already running
  unload_daemon

  # Install plist
  echo "[bootstrap] Copying plist to ${PLIST_DST}..."
  sudo cp "${PLIST_SRC}" "${PLIST_DST}"
  sudo chown root:wheel "${PLIST_DST}"
  sudo chmod 644 "${PLIST_DST}"

  # Install binary if available
  if [[ -n "${binary_src}" ]]; then
    echo "[bootstrap] Copying winrund binary to ${BINARY_DST}..."
    sudo mkdir -p "$(dirname "${BINARY_DST}")"
    sudo cp "${binary_src}" "${BINARY_DST}"
    sudo chown root:wheel "${BINARY_DST}"
    sudo chmod 755 "${BINARY_DST}"
  else
    echo "[bootstrap] winrund binary not found."
    echo "[bootstrap] Build first with: cd host && swift build -c release"
    if [[ ! -f "${BINARY_DST}" ]]; then
      echo "[bootstrap] Skipping daemon load - no binary available."
      echo "[bootstrap] Plist installed. Re-run --install-daemon after building."
      return 0
    fi
    echo "[bootstrap] Using existing binary at ${BINARY_DST}"
  fi

  # Load the daemon
  echo "[bootstrap] Loading daemon..."
  sudo launchctl bootstrap system "${PLIST_DST}"

  echo "[bootstrap] LaunchDaemon installed and running."
  echo "[bootstrap] Check status with: sudo launchctl print system/${DAEMON_LABEL}"
}

# Uninstall the LaunchDaemon
uninstall_daemon() {
  echo "[bootstrap] Uninstalling LaunchDaemon..."

  unload_daemon

  if [[ -f "${PLIST_DST}" ]]; then
    echo "[bootstrap] Removing plist..."
    sudo rm -f "${PLIST_DST}"
  fi

  if [[ -f "${BINARY_DST}" ]]; then
    echo "[bootstrap] Removing binary..."
    sudo rm -f "${BINARY_DST}"
  fi

  echo "[bootstrap] LaunchDaemon uninstalled."
}

# Main bootstrap logic
bootstrap() {
  if [[ "${OSTYPE}" != "darwin"* ]]; then
    echo "[bootstrap] This script must be run on macOS to provision the WinRun host stack." >&2
    exit 1
  fi

  echo "[bootstrap] Installing brew dependencies..."
  brew bundle --file="${REPO_ROOT}/Brewfile"

  echo "[bootstrap] Creating Application Support directory..."
  mkdir -p "${HOME}/Library/Application Support/WinRun"

  echo "[bootstrap] Ready to build WinRun components."
}

# Parse arguments
INSTALL_DAEMON=false
UNINSTALL_DAEMON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-daemon)
      INSTALL_DAEMON=true
      shift
      ;;
    --uninstall-daemon)
      UNINSTALL_DAEMON=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[bootstrap] Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Execute
if [[ "${UNINSTALL_DAEMON}" == "true" ]]; then
  uninstall_daemon
  exit 0
fi

bootstrap

if [[ "${INSTALL_DAEMON}" == "true" ]]; then
  install_daemon
fi

echo "[bootstrap] Done."
