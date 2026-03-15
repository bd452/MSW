#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOTNET_CHANNEL="${DOTNET_CHANNEL:-8.0}"
DOTNET_SDK_VERSION="${DOTNET_SDK_VERSION:-}"
DOTNET_WINDOWS_HOME="${DOTNET_WINDOWS_HOME:-${HOME}/.dotnet-windows}"
WINE_DOTNET_EXE="${WINE_DOTNET_EXE:-${DOTNET_WINDOWS_HOME}/dotnet.exe}"
LINUX_DOTNET_CHANNEL="${LINUX_DOTNET_CHANNEL:-9.0}"
LINUX_DOTNET_HOME="${LINUX_DOTNET_HOME:-${HOME}/.dotnet}"
WINEPREFIX="${WINEPREFIX:-${HOME}/.wine-winrun}"

INSTALL_PACKAGES=1
INSTALL_DOTNET=1
INSTALL_LINUX_DOTNET=1
VERIFY_ONLY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Install and verify Linux prerequisites for Wine-assisted Windows guest tests.

Options:
  --verify-only        Verify prerequisites only; do not install anything
  --skip-packages      Skip package-manager dependency installation
  --skip-dotnet        Skip Windows .NET SDK download/install
  --skip-linux-dotnet  Skip Linux .NET SDK download/install
  --channel <value>    .NET release channel (default: ${DOTNET_CHANNEL})
  --dotnet-version <v> Explicit Windows SDK version (default: latest in channel)
  --dotnet-home <dir>  Install directory for Windows SDK (default: ${DOTNET_WINDOWS_HOME})
  -h, --help           Show this help message

Environment variables:
  DOTNET_CHANNEL
  DOTNET_SDK_VERSION
  DOTNET_WINDOWS_HOME
  LINUX_DOTNET_CHANNEL
  LINUX_DOTNET_HOME
  WINE_DOTNET_EXE
  WINEPREFIX (default: ${WINEPREFIX})
EOF
}

log() {
  echo "[setup-wine-tests] $*"
}

warn() {
  echo "[setup-wine-tests] WARNING: $*" >&2
}

die() {
  echo "[setup-wine-tests] ERROR: $*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "Need root privileges to install packages. Re-run as root or install sudo."
  fi
}

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

install_packages_apt() {
  local arch

  log "Detected apt-get package manager"

  arch="$(dpkg --print-architecture)"
  if [[ "${arch}" == "amd64" ]]; then
    if ! dpkg --print-foreign-architectures | grep -qx "i386"; then
      log "Enabling i386 multiarch for Wine compatibility"
      run_as_root dpkg --add-architecture i386
    fi
  else
    warn "Non-amd64 architecture (${arch}) detected; skipping wine32:i386 installation"
  fi

  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl jq unzip wine64 wine

  if [[ "${arch}" == "amd64" ]]; then
    run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends wine32:i386
  fi

  # Optional packages improve compatibility but are not always available.
  if ! run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends winetricks; then
    warn "Optional package 'winetricks' could not be installed"
  fi
}

install_packages_dnf() {
  log "Detected dnf package manager"
  run_as_root dnf install -y ca-certificates curl jq unzip wine
  if ! run_as_root dnf install -y winetricks; then
    warn "Optional package 'winetricks' could not be installed"
  fi
}

install_packages_yum() {
  log "Detected yum package manager"
  run_as_root yum install -y ca-certificates curl jq unzip wine
  if ! run_as_root yum install -y winetricks; then
    warn "Optional package 'winetricks' could not be installed"
  fi
}

install_packages_pacman() {
  log "Detected pacman package manager"
  run_as_root pacman -Sy --noconfirm --needed ca-certificates curl jq unzip wine
  if ! run_as_root pacman -Sy --noconfirm --needed winetricks; then
    warn "Optional package 'winetricks' could not be installed"
  fi
}

install_packages_zypper() {
  log "Detected zypper package manager"
  run_as_root zypper --non-interactive install --no-recommends ca-certificates curl jq unzip wine
  if ! run_as_root zypper --non-interactive install --no-recommends winetricks; then
    warn "Optional package 'winetricks' could not be installed"
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    install_packages_apt
  elif command -v dnf >/dev/null 2>&1; then
    install_packages_dnf
  elif command -v yum >/dev/null 2>&1; then
    install_packages_yum
  elif command -v pacman >/dev/null 2>&1; then
    install_packages_pacman
  elif command -v zypper >/dev/null 2>&1; then
    install_packages_zypper
  else
    die "No supported package manager found (apt/dnf/yum/pacman/zypper)"
  fi
}

resolve_windows_sdk_url() {
  local metadata_file="$1"
  local sdk_version="$2"

  jq -r --arg v "${sdk_version}" '
    .releases[]
    | select(.sdk.version == $v)
    | .sdk.files[]
    | select(.rid == "win-x64" and (.url | endswith(".zip")))
    | .url
  ' "${metadata_file}" | head -n 1
}

resolve_guest_sdk_version() {
  local global_json="${REPO_ROOT}/guest/global.json"

  if [[ -f "${global_json}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r '.sdk.version // empty' "${global_json}"
    else
      sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "${global_json}" | head -n 1
    fi
  else
    echo ""
  fi
}

dotnet_has_sdk_version() {
  local dotnet_cmd="$1"
  local sdk_version="$2"

  "${dotnet_cmd}" --list-sdks | awk '{print $1}' | grep -qx "${sdk_version}"
}

install_windows_dotnet() {
  local metadata_url="https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/${DOTNET_CHANNEL}/releases.json"
  local metadata_file
  local sdk_version
  local sdk_url
  local zip_file

  require_command curl
  require_command jq
  require_command unzip

  mkdir -p "${DOTNET_WINDOWS_HOME}"

  if [[ -f "${WINE_DOTNET_EXE}" ]]; then
    log "Windows dotnet.exe already present at ${WINE_DOTNET_EXE}; skipping download"
    return
  fi

  metadata_file="$(mktemp)"
  zip_file="$(mktemp --suffix=.zip)"

  log "Fetching .NET release metadata from ${metadata_url}"
  curl -fsSL "${metadata_url}" -o "${metadata_file}"

  if [[ -n "${DOTNET_SDK_VERSION}" ]]; then
    sdk_version="${DOTNET_SDK_VERSION}"
  else
    sdk_version="$(jq -r '."latest-sdk"' "${metadata_file}")"
  fi

  [[ -n "${sdk_version}" && "${sdk_version}" != "null" ]] || die "Could not determine SDK version"

  sdk_url="$(resolve_windows_sdk_url "${metadata_file}" "${sdk_version}")"
  [[ -n "${sdk_url}" ]] || die "Could not resolve win-x64 SDK URL for version ${sdk_version}"

  log "Downloading Windows .NET SDK ${sdk_version}"
  curl -fL "${sdk_url}" -o "${zip_file}"

  log "Extracting SDK into ${DOTNET_WINDOWS_HOME}"
  unzip -q -o "${zip_file}" -d "${DOTNET_WINDOWS_HOME}"

  rm -f "${metadata_file}" "${zip_file}"

  [[ -f "${WINE_DOTNET_EXE}" ]] || die "dotnet.exe was not found after extraction"

  log "Installed Windows dotnet.exe at ${WINE_DOTNET_EXE}"
}

install_linux_dotnet() {
  local installer_script
  local dotnet_cmd=""
  local required_sdk=""

  if command -v dotnet >/dev/null 2>&1; then
    dotnet_cmd="$(command -v dotnet)"
  elif [[ -x "${LINUX_DOTNET_HOME}/dotnet" ]]; then
    dotnet_cmd="${LINUX_DOTNET_HOME}/dotnet"
  fi

  required_sdk="$(resolve_guest_sdk_version)"

  if [[ -n "${dotnet_cmd}" ]]; then
    if [[ -n "${required_sdk}" ]]; then
      if dotnet_has_sdk_version "${dotnet_cmd}" "${required_sdk}"; then
        log "Linux dotnet SDK ${required_sdk} already available; skipping install"
        return
      fi
      log "Linux dotnet SDK found, but missing required guest SDK ${required_sdk}; installing it"
    else
      log "Linux dotnet SDK already available; skipping install"
      return
    fi
  fi

  require_command curl
  require_command bash

  installer_script="$(mktemp)"
  curl -fsSL "https://dot.net/v1/dotnet-install.sh" -o "${installer_script}"

  mkdir -p "${LINUX_DOTNET_HOME}"
  if [[ -n "${required_sdk}" ]]; then
    log "Installing Linux .NET SDK ${required_sdk} into ${LINUX_DOTNET_HOME}"
    bash "${installer_script}" --version "${required_sdk}" --install-dir "${LINUX_DOTNET_HOME}" --no-path
  else
    log "Installing Linux .NET SDK channel ${LINUX_DOTNET_CHANNEL} into ${LINUX_DOTNET_HOME}"
    bash "${installer_script}" --channel "${LINUX_DOTNET_CHANNEL}" --install-dir "${LINUX_DOTNET_HOME}" --no-path
  fi
  rm -f "${installer_script}"

  [[ -x "${LINUX_DOTNET_HOME}/dotnet" ]] || die "Linux dotnet install failed"
}

verify_prereqs() {
  local missing=0
  local wine_bin=""
  local info_log
  local linux_dotnet=""
  local required_linux_sdk=""

  require_command mktemp
  require_command sed

  if command -v wine64 >/dev/null 2>&1; then
    wine_bin="wine64"
  elif command -v wine >/dev/null 2>&1; then
    wine_bin="wine"
  fi

  if [[ -z "${wine_bin}" ]]; then
    echo "❌ Missing prerequisite: Wine executable (wine or wine64)"
    missing=1
  fi

  if [[ ! -f "${WINE_DOTNET_EXE}" ]]; then
    echo "❌ Missing prerequisite: Windows dotnet.exe at ${WINE_DOTNET_EXE}"
    missing=1
  fi

  if [[ "${missing}" -ne 0 ]]; then
    echo ""
    echo "Run setup with:"
    echo "  make setup-wine-tests"
    return 1
  fi

  if command -v dotnet >/dev/null 2>&1; then
    linux_dotnet="dotnet"
  elif [[ -x "${LINUX_DOTNET_HOME}/dotnet" ]]; then
    linux_dotnet="${LINUX_DOTNET_HOME}/dotnet"
  fi

  required_linux_sdk="$(resolve_guest_sdk_version)"

  if [[ -z "${linux_dotnet}" ]]; then
    warn "Linux dotnet SDK not found; 'make check-linux-mid' may fail in check-linux phase"
  elif [[ -n "${required_linux_sdk}" ]]; then
    if ! dotnet_has_sdk_version "${linux_dotnet}" "${required_linux_sdk}"; then
      warn "Linux dotnet is missing guest-required SDK ${required_linux_sdk}; run make setup-wine-tests"
    fi
  fi

  # Initialize/update prefix once so later test runs don't pay first-run setup cost.
  export WINEPREFIX
  WINEDEBUG=-all wineboot --init >/dev/null 2>&1 || true

  info_log="$(mktemp)"

  if ! WINEDEBUG=-all run_wine_command "${wine_bin}" "${WINE_DOTNET_EXE}" --info >"${info_log}" 2>&1; then
    warn "dotnet.exe did not start successfully under Wine"
    echo "---- dotnet --info (Wine) output ----"
    sed -n '1,60p' "${info_log}"
    echo "-------------------------------------"
    rm -f "${info_log}"
    return 1
  fi

  rm -f "${info_log}"

  echo "✅ Wine guest-test prerequisites are ready"
  echo "   Wine binary: ${wine_bin}"
  echo "   Windows dotnet.exe: ${WINE_DOTNET_EXE}"
  if [[ -n "${linux_dotnet}" ]]; then
    echo "   Linux dotnet: ${linux_dotnet}"
  fi
  echo "   WINEPREFIX: ${WINEPREFIX}"
  echo "   Mid-task loop: make check-linux-mid"
  echo "   Final gate:    make test-guest-remote"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verify-only)
        VERIFY_ONLY=1
        INSTALL_PACKAGES=0
        INSTALL_DOTNET=0
        shift
        ;;
      --skip-packages)
        INSTALL_PACKAGES=0
        shift
        ;;
      --skip-dotnet)
        INSTALL_DOTNET=0
        shift
        ;;
      --skip-linux-dotnet)
        INSTALL_LINUX_DOTNET=0
        shift
        ;;
      --channel)
        DOTNET_CHANNEL="${2:-}"
        [[ -n "${DOTNET_CHANNEL}" ]] || die "--channel requires a value"
        shift 2
        ;;
      --dotnet-version)
        DOTNET_SDK_VERSION="${2:-}"
        [[ -n "${DOTNET_SDK_VERSION}" ]] || die "--dotnet-version requires a value"
        shift 2
        ;;
      --dotnet-home)
        DOTNET_WINDOWS_HOME="${2:-}"
        [[ -n "${DOTNET_WINDOWS_HOME}" ]] || die "--dotnet-home requires a value"
        WINE_DOTNET_EXE="${DOTNET_WINDOWS_HOME}/dotnet.exe"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  if [[ "$(uname -s)" != "Linux" ]]; then
    die "This setup script currently supports Linux only"
  fi

  if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
    verify_prereqs
    return
  fi

  if [[ "${INSTALL_PACKAGES}" -eq 1 ]]; then
    install_packages
  fi

  if [[ "${INSTALL_DOTNET}" -eq 1 ]]; then
    install_windows_dotnet
  fi

  if [[ "${INSTALL_LINUX_DOTNET}" -eq 1 ]]; then
    install_linux_dotnet
  fi

  verify_prereqs
}

main "$@"
