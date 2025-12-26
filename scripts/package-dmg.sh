#!/usr/bin/env bash
# =============================================================================
# package-dmg.sh - Create distributable DMG for WinRun.app
# =============================================================================
#
# Creates a DMG with a drag-to-Applications layout:
#   - WinRun.app
#   - /Applications symlink
#
# The script uses only built-in macOS tooling (hdiutil + osascript).
#
# Usage:
#   ./scripts/package-dmg.sh [options]
#
# Options:
#   --app PATH         Path to WinRun.app (default: build/WinRun.app)
#   --output PATH      Output DMG path (default: build/WinRun.dmg)
#   --volname NAME     DMG volume name (default: WinRun)
#   --background PATH  Background image to use (optional)
#   --window-size WxH  Finder window size (default: 640x420)
#   --help             Show this help message
#
# Notes:
# - Must be run on macOS.
# - For signing/notarization, use scripts/sign-and-notarize.sh on the final DMG.
#
# =============================================================================

set -euo pipefail

SCRIPT_ROOT="$(cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_ROOT}/.." && pwd)"

# Defaults
APP_PATH="${REPO_ROOT}/build/WinRun.app"
OUTPUT_DMG="${REPO_ROOT}/build/WinRun.dmg"
VOLNAME="WinRun"
BACKGROUND_PATH=""
WINDOW_W=640
WINDOW_H=420

# Color output helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

show_help() {
    sed -n '1,/^# ===.*$/{ /^#/!d; s/^# //; s/^#$//; p; }' "$0"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_PATH="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DMG="$2"
            shift 2
            ;;
        --volname)
            VOLNAME="$2"
            shift 2
            ;;
        --background)
            BACKGROUND_PATH="$2"
            shift 2
            ;;
        --window-size)
            if [[ "$2" =~ ^([0-9]+)x([0-9]+)$ ]]; then
                WINDOW_W="${BASH_REMATCH[1]}"
                WINDOW_H="${BASH_REMATCH[2]}"
            else
                log_error "Invalid --window-size. Expected WxH (e.g., 640x420)"
                exit 1
            fi
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

require_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        log_error "This script must be run on macOS"
        exit 1
    fi
}

validate_inputs() {
    if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
        log_error "App bundle not found (or not a .app): $APP_PATH"
        log_error "Build/package first (e.g., ./scripts/package-app.sh --output build/WinRun.app)"
        exit 1
    fi

    if [[ -n "$BACKGROUND_PATH" && ! -f "$BACKGROUND_PATH" ]]; then
        log_error "Background image not found: $BACKGROUND_PATH"
        exit 1
    fi

    mkdir -p "$(dirname "$OUTPUT_DMG")"
}

create_staging_dir() {
    STAGING_DIR="$(mktemp -d)"
    log_info "Creating staging dir: $STAGING_DIR"

    # Copy the app bundle (preserve extended attributes/resource forks)
    ditto "$APP_PATH" "${STAGING_DIR}/$(basename "$APP_PATH")"

    # Create Applications shortcut
    ln -s /Applications "${STAGING_DIR}/Applications"

    # Optional background
    if [[ -n "$BACKGROUND_PATH" ]]; then
        mkdir -p "${STAGING_DIR}/.background"
        cp "$BACKGROUND_PATH" "${STAGING_DIR}/.background/$(basename "$BACKGROUND_PATH")"
    fi
}

cleanup_staging_dir() {
    if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
    fi
}

calculate_dmg_size_mb() {
    # du -sk is POSIX-ish and available on macOS
    local kb
    kb=$(du -sk "$STAGING_DIR" | awk '{print $1}')

    # Add padding for Finder metadata, background, etc.
    local kb_with_padding=$((kb + 20 * 1024))
    local mb=$(((kb_with_padding / 1024) + 1))
    echo "$mb"
}

create_rw_dmg() {
    local size_mb
    size_mb="$(calculate_dmg_size_mb)"
    log_info "Creating temp read/write DMG (~${size_mb}MB)..."

    RW_DMG="$(mktemp -t winrun.XXXXXX.dmg)"
    hdiutil create \
        -volname "$VOLNAME" \
        -srcfolder "$STAGING_DIR" \
        -fs HFS+ \
        -format UDRW \
        -size "${size_mb}m" \
        "$RW_DMG" >/dev/null
}

attach_dmg() {
    MOUNT_POINT="$(mktemp -d /tmp/winrun-dmg-mount.XXXXXX)"
    log_info "Attaching DMG at: $MOUNT_POINT"

    # -nobrowse prevents Finder from auto-opening new windows in most cases
    # -noverify speeds up for local temp images
    hdiutil attach \
        -readwrite \
        -noverify \
        -noautoopen \
        -nobrowse \
        -mountpoint "$MOUNT_POINT" \
        "$RW_DMG" >/dev/null
}

detach_dmg() {
    if [[ -n "${MOUNT_POINT:-}" && -d "$MOUNT_POINT" ]]; then
        log_info "Detaching DMG..."
        hdiutil detach "$MOUNT_POINT" -quiet || {
            log_warn "Initial detach failed; retrying with force..."
            hdiutil detach "$MOUNT_POINT" -force -quiet
        }
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
}

configure_finder_layout() {
    log_info "Configuring Finder window layout..."

    local dmg_app_name
    dmg_app_name="$(basename "$APP_PATH")"

    local bg_file_name=""
    if [[ -n "$BACKGROUND_PATH" ]]; then
        bg_file_name="$(basename "$BACKGROUND_PATH")"
    fi

    # Give Finder a moment to notice the newly mounted volume.
    sleep 1

    # Finder scripting: set icon view, window size, icon positions, background.
    # Note: AppleScript coordinates are in points from top-left of the window content area.
    osascript >/dev/null <<EOF
tell application "Finder"
  tell disk "${VOLNAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 100 + ${WINDOW_W}, 100 + ${WINDOW_H}}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128

    if "${bg_file_name}" is not "" then
      set background picture of opts to file ".background:${bg_file_name}"
    end if

    try
      set position of item "${dmg_app_name}" to {160, 220}
    end try
    try
      set position of item "Applications" to {480, 220}
    end try

    close
    open
    update without registering applications
    delay 1
  end tell
end tell
EOF
}

finalize_dmg() {
    log_info "Converting DMG to compressed UDZO..."

    # Remove existing output to avoid hdiutil prompt failures
    if [[ -f "$OUTPUT_DMG" ]]; then
        rm -f "$OUTPUT_DMG"
    fi

    hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG" >/dev/null

    log_success "DMG created: $OUTPUT_DMG"
}

cleanup_rw_dmg() {
    if [[ -n "${RW_DMG:-}" && -f "$RW_DMG" ]]; then
        rm -f "$RW_DMG"
    fi
}

cleanup_all() {
    # Order matters: detach before deleting underlying dmg file.
    detach_dmg || true
    cleanup_rw_dmg || true
    cleanup_staging_dir || true
}

main() {
    echo ""
    log_info "WinRun DMG Packager"
    echo ""

    require_macos
    validate_inputs

    trap cleanup_all EXIT

    create_staging_dir
    create_rw_dmg
    attach_dmg

    configure_finder_layout
    detach_dmg

    finalize_dmg

    echo ""
    echo "============================================"
    log_success "WinRun DMG created successfully!"
    echo "============================================"
    echo ""
    echo "Output: ${OUTPUT_DMG}"
    echo ""
    echo "Next steps:"
    echo "  1. Test DMG: open '${OUTPUT_DMG}'"
    echo "  2. Sign/Notarize: ./scripts/sign-and-notarize.sh '${OUTPUT_DMG}'"
    echo ""
}

main "$@"
