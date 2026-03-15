#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_PREFIX="${HOME}/.winrun/tools/qemu-spice"
PREFIX="${WINRUN_MANAGED_QEMU_PREFIX:-$DEFAULT_PREFIX}"
SRC_ROOT="${HOME}/.winrun/tools/src"
QEMU_SRC_DIR="${SRC_ROOT}/qemu"
JOBS="${WINRUN_QEMU_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
PYTHON_BIN=""

log() {
  echo "[qemu-bootstrap] $*"
}

error() {
  echo "[qemu-bootstrap] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "missing required command: $1"
}

ensure_macos() {
  [[ "${OSTYPE:-}" == darwin* ]] || error "this script requires macOS"
}

ensure_dependencies() {
  require_cmd brew
  require_cmd git

  log "Installing build/runtime dependencies with Homebrew..."
  brew install \
    glib pixman gnutls libslirp libssh libusb capstone dtc lzo zstd vde snappy \
    spice-protocol spice-server jpeg-turbo libpng ncurses pkg-config meson ninja

  require_cmd meson
  require_cmd ninja

  if command -v brew >/dev/null 2>&1; then
    local brew_py_prefix
    brew_py_prefix="$(brew --prefix python@3.14 2>/dev/null || true)"
    if [[ -n "${brew_py_prefix}" && -x "${brew_py_prefix}/bin/python3.14" ]]; then
      PYTHON_BIN="${brew_py_prefix}/bin/python3.14"
    elif [[ -n "${brew_py_prefix}" && -x "${brew_py_prefix}/bin/python3" ]]; then
      PYTHON_BIN="${brew_py_prefix}/bin/python3"
    fi
  fi

  if [[ -z "${PYTHON_BIN}" ]]; then
    PYTHON_BIN="$(command -v python3 || true)"
  fi
  [[ -n "${PYTHON_BIN}" ]] || error "could not locate a usable python3 binary"
}

is_prefix_ready() {
  local bin="${PREFIX}/bin/qemu-system-aarch64"
  if [[ ! -x "${bin}" ]]; then
    return 1
  fi
  if "${REPO_ROOT}/scripts/check-qemu-spice.sh" "${bin}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

prepare_source() {
  mkdir -p "${SRC_ROOT}"
  if [[ -d "${QEMU_SRC_DIR}/.git" ]]; then
    log "Updating existing QEMU source checkout..."
    git -C "${QEMU_SRC_DIR}" fetch --depth=1 origin master
    git -C "${QEMU_SRC_DIR}" checkout --force FETCH_HEAD
  else
    log "Cloning QEMU source..."
    git clone --depth=1 https://gitlab.com/qemu-project/qemu.git "${QEMU_SRC_DIR}"
  fi
}

build_and_install() {
  mkdir -p "${PREFIX}"
  pushd "${QEMU_SRC_DIR}" >/dev/null

  log "Configuring QEMU build (prefix: ${PREFIX})..."
  rm -rf build
  export PATH="$(dirname "${PYTHON_BIN}"):${PATH}"
  ./configure \
    --prefix="${PREFIX}" \
    --target-list="aarch64-softmmu" \
    --enable-spice \
    --enable-slirp \
    --disable-cocoa \
    --disable-gtk \
    --disable-sdl \
    --disable-docs \
    --disable-werror \
    --enable-tools \
    --python="${PYTHON_BIN}"

  log "Building QEMU (jobs: ${JOBS})..."
  make -j "${JOBS}"

  log "Installing QEMU into managed prefix..."
  make install

  popd >/dev/null
}

print_next_steps() {
  cat <<EOF
[qemu-bootstrap] Installed managed SPICE-enabled QEMU:
  ${PREFIX}/bin/qemu-system-aarch64

[qemu-bootstrap] Environment overrides for ad-hoc runs:
  WINRUN_QEMU_PREFIX="${PREFIX}"
  WINRUN_SWTPM_PREFIX="\$(brew --prefix swtpm 2>/dev/null || echo /opt/homebrew)"
EOF
}

main() {
  ensure_macos

  if is_prefix_ready; then
    log "Managed QEMU already present and SPICE-capable at ${PREFIX}"
    print_next_steps
    return
  fi

  ensure_dependencies
  prepare_source
  build_and_install

  if ! is_prefix_ready; then
    error "build completed but managed QEMU still does not report SPICE support"
  fi

  print_next_steps
}

main "$@"
