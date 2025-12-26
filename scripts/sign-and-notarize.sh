#!/usr/bin/env bash
# =============================================================================
# sign-and-notarize.sh - Code sign and notarize WinRun.app for distribution
# =============================================================================
#
# This script signs the app bundle with a Developer ID certificate, submits
# it to Apple for notarization, and staples the notarization ticket.
#
# Usage:
#   ./scripts/sign-and-notarize.sh [options] <path-to-app-or-dmg>
#
# Options:
#   --skip-notarization   Sign only, skip notarization (for development)
#   --skip-staple         Submit for notarization but don't wait/staple
#   --dry-run             Print what would be done without executing
#   --verbose             Enable verbose output
#   --help                Show this help message
#
# Environment Variables (Required for full operation):
#   DEVELOPER_ID          Developer ID Application certificate name or SHA-1
#                         Example: "Developer ID Application: Your Name (TEAM_ID)"
#
#   For notarization, provide ONE of these authentication methods:
#
#   Method 1 - App Store Connect API Key (Recommended for CI):
#     NOTARIZE_KEY_ID       App Store Connect API Key ID
#     NOTARIZE_KEY_ISSUER   App Store Connect API Key Issuer ID
#     NOTARIZE_KEY_PATH     Path to AuthKey_*.p8 file
#
#   Method 2 - Apple ID with App-Specific Password:
#     NOTARIZE_APPLE_ID     Apple ID email
#     NOTARIZE_PASSWORD     App-specific password (or @keychain:item-name)
#     NOTARIZE_TEAM_ID      Team ID (10-character string)
#
# Examples:
#   # Sign and notarize with API key
#   export DEVELOPER_ID="Developer ID Application: WinRun Inc (ABC123XYZ)"
#   export NOTARIZE_KEY_ID="ABC123"
#   export NOTARIZE_KEY_ISSUER="def-456-ghi"
#   export NOTARIZE_KEY_PATH="$HOME/.appstoreconnect/AuthKey_ABC123.p8"
#   ./scripts/sign-and-notarize.sh build/WinRun.app
#
#   # Sign only (for development/testing)
#   export DEVELOPER_ID="Developer ID Application: WinRun Inc (ABC123XYZ)"
#   ./scripts/sign-and-notarize.sh --skip-notarization build/WinRun.app
#
#   # Dry run to see what would happen
#   ./scripts/sign-and-notarize.sh --dry-run build/WinRun.app
#
# Credential Setup:
#   See docs/development.md section "Code Signing & Notarization Setup" for
#   detailed instructions on obtaining and configuring credentials.
#
# =============================================================================

set -euo pipefail

SCRIPT_ROOT="$(cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_ROOT}/.." && pwd)"

# Default options
SKIP_NOTARIZATION=false
SKIP_STAPLE=false
DRY_RUN=false
VERBOSE=false
TARGET_PATH=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarization)
            SKIP_NOTARIZATION=true
            shift
            ;;
        --skip-staple)
            SKIP_STAPLE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            sed -n '1,/^# ===.*$/{ /^#/!d; s/^# //; s/^#$//; p; }' "$0"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            TARGET_PATH="$1"
            shift
            ;;
    esac
done

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
log_debug() { [[ "$VERBOSE" == "true" ]] && echo -e "[DEBUG] $1" || true; }

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        log_debug "Running: $*"
        "$@"
    fi
}

# =============================================================================
# Validate inputs and environment
# =============================================================================

validate_inputs() {
    # Check we're on macOS
    if [[ "$(uname -s)" != "Darwin" ]]; then
        log_error "This script must be run on macOS"
        exit 1
    fi

    # Check target path is provided
    if [[ -z "$TARGET_PATH" ]]; then
        log_error "No target path provided"
        echo ""
        echo "Usage: $0 [options] <path-to-app-or-dmg>"
        echo "Run '$0 --help' for full usage information"
        exit 1
    fi

    # Check target exists
    if [[ ! -e "$TARGET_PATH" ]]; then
        log_error "Target not found: $TARGET_PATH"
        exit 1
    fi

    # Determine target type
    if [[ -d "$TARGET_PATH" && "$TARGET_PATH" == *.app ]]; then
        TARGET_TYPE="app"
    elif [[ -f "$TARGET_PATH" && "$TARGET_PATH" == *.dmg ]]; then
        TARGET_TYPE="dmg"
    elif [[ -f "$TARGET_PATH" && "$TARGET_PATH" == *.pkg ]]; then
        TARGET_TYPE="pkg"
    elif [[ -f "$TARGET_PATH" && "$TARGET_PATH" == *.zip ]]; then
        TARGET_TYPE="zip"
    else
        log_error "Unsupported target type. Expected .app, .dmg, .pkg, or .zip"
        exit 1
    fi

    log_info "Target: ${TARGET_PATH} (${TARGET_TYPE})"
}

check_signing_credentials() {
    log_info "Checking code signing credentials..."

    if [[ -z "${DEVELOPER_ID:-}" ]]; then
        log_warn "DEVELOPER_ID not set - code signing will be skipped"
        log_warn ""
        log_warn "To enable code signing, set the DEVELOPER_ID environment variable:"
        log_warn "  export DEVELOPER_ID=\"Developer ID Application: Your Name (TEAM_ID)\""
        log_warn ""
        log_warn "You can find your certificate name with:"
        log_warn "  security find-identity -v -p codesigning"
        log_warn ""
        log_warn "See docs/development.md for credential setup instructions."
        return 1
    fi

    # Verify the certificate exists in keychain
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID"; then
            log_error "Certificate not found in keychain: $DEVELOPER_ID"
            log_error ""
            log_error "Available code signing identities:"
            security find-identity -v -p codesigning || true
            log_error ""
            log_error "Make sure the certificate is installed in your keychain."
            return 1
        fi
    fi

    log_success "Code signing credentials verified: $DEVELOPER_ID"
    return 0
}

check_notarization_credentials() {
    if [[ "$SKIP_NOTARIZATION" == "true" ]]; then
        log_info "Skipping notarization credential check (--skip-notarization)"
        return 1  # Return 1 to indicate notarization should be skipped
    fi

    log_info "Checking notarization credentials..."

    # Check for API Key authentication (recommended for CI)
    if [[ -n "${NOTARIZE_KEY_ID:-}" && -n "${NOTARIZE_KEY_ISSUER:-}" && -n "${NOTARIZE_KEY_PATH:-}" ]]; then
        if [[ ! -f "$NOTARIZE_KEY_PATH" && "$DRY_RUN" != "true" ]]; then
            log_error "API key file not found: $NOTARIZE_KEY_PATH"
            return 1
        fi
        NOTARIZE_METHOD="apikey"
        log_success "Using App Store Connect API Key for notarization"
        return 0
    fi

    # Check for Apple ID authentication
    if [[ -n "${NOTARIZE_APPLE_ID:-}" && -n "${NOTARIZE_PASSWORD:-}" && -n "${NOTARIZE_TEAM_ID:-}" ]]; then
        NOTARIZE_METHOD="appleid"
        log_success "Using Apple ID for notarization"
        return 0
    fi

    # No credentials found
    log_warn "Notarization credentials not configured - notarization will be skipped"
    log_warn ""
    log_warn "To enable notarization, set one of these credential sets:"
    log_warn ""
    log_warn "Method 1 - App Store Connect API Key (Recommended for CI):"
    log_warn "  export NOTARIZE_KEY_ID=\"ABC123\""
    log_warn "  export NOTARIZE_KEY_ISSUER=\"def-456-ghi\""
    log_warn "  export NOTARIZE_KEY_PATH=\"\$HOME/.appstoreconnect/AuthKey_ABC123.p8\""
    log_warn ""
    log_warn "Method 2 - Apple ID with App-Specific Password:"
    log_warn "  export NOTARIZE_APPLE_ID=\"developer@example.com\""
    log_warn "  export NOTARIZE_PASSWORD=\"@keychain:AC_PASSWORD\""
    log_warn "  export NOTARIZE_TEAM_ID=\"ABC123XYZ\""
    log_warn ""
    log_warn "See docs/development.md for credential setup instructions."
    return 1
}

# =============================================================================
# Code signing
# =============================================================================

sign_target() {
    log_info "Signing ${TARGET_TYPE}: ${TARGET_PATH}..."

    local codesign_args=(
        --force
        --verify
        --verbose
        --sign "$DEVELOPER_ID"
        --options runtime  # Required for notarization (hardened runtime)
        --timestamp        # Required for notarization
    )

    if [[ "$TARGET_TYPE" == "app" ]]; then
        # For app bundles, sign deeply (all nested code)
        codesign_args+=(--deep)

        # Sign frameworks first if they exist
        local frameworks_dir="${TARGET_PATH}/Contents/Frameworks"
        if [[ -d "$frameworks_dir" ]]; then
            log_info "Signing embedded frameworks..."
            shopt -s nullglob
            for framework in "$frameworks_dir"/*.framework "$frameworks_dir"/*.dylib; do
                [[ -e "$framework" ]] || continue
                log_debug "Signing: $framework"
                run_cmd codesign "${codesign_args[@]}" "$framework"
            done
            shopt -u nullglob
        fi

        # Sign helper executables if they exist
        local helpers_dir="${TARGET_PATH}/Contents/MacOS"
        if [[ -d "$helpers_dir" ]]; then
            log_info "Signing executables..."
            for executable in "$helpers_dir"/*; do
                [[ -x "$executable" ]] || continue
                log_debug "Signing: $executable"
                run_cmd codesign "${codesign_args[@]}" "$executable"
            done
        fi
    fi

    # Sign the main target
    run_cmd codesign "${codesign_args[@]}" "$TARGET_PATH"

    # Verify the signature
    if [[ "$DRY_RUN" != "true" ]]; then
        log_info "Verifying signature..."
        if codesign --verify --deep --strict "$TARGET_PATH" 2>&1; then
            log_success "Signature verified successfully"
        else
            log_error "Signature verification failed"
            return 1
        fi

        # Check for notarization compatibility
        log_info "Checking notarization compatibility..."
        if spctl --assess --type execute --verbose "$TARGET_PATH" 2>&1; then
            log_success "Gatekeeper assessment passed"
        else
            log_warn "Gatekeeper assessment may require notarization"
        fi
    else
        log_success "Signing completed (dry-run)"
    fi
}

# =============================================================================
# Notarization
# =============================================================================

notarize_target() {
    log_info "Submitting for notarization..."

    local notarytool_args=(submit)

    # Build authentication arguments based on method
    case "${NOTARIZE_METHOD:-}" in
        apikey)
            notarytool_args+=(
                --key "$NOTARIZE_KEY_PATH"
                --key-id "$NOTARIZE_KEY_ID"
                --issuer "$NOTARIZE_KEY_ISSUER"
            )
            ;;
        appleid)
            notarytool_args+=(
                --apple-id "$NOTARIZE_APPLE_ID"
                --password "$NOTARIZE_PASSWORD"
                --team-id "$NOTARIZE_TEAM_ID"
            )
            ;;
        *)
            log_error "Unknown notarization method: ${NOTARIZE_METHOD:-}"
            return 1
            ;;
    esac

    # Add target path
    local submit_path="$TARGET_PATH"

    # For app bundles, create a zip for submission
    if [[ "$TARGET_TYPE" == "app" ]]; then
        log_info "Creating zip archive for notarization submission..."
        submit_path="${TARGET_PATH%.app}.zip"
        run_cmd ditto -c -k --keepParent "$TARGET_PATH" "$submit_path"
    fi

    notarytool_args+=("$submit_path")

    # Add wait flag unless skipping staple
    if [[ "$SKIP_STAPLE" != "true" ]]; then
        notarytool_args+=(--wait)
    fi

    # Submit for notarization
    log_info "Submitting to Apple notary service..."
    local submission_output
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} xcrun notarytool ${notarytool_args[*]}"
        submission_output="id: dry-run-submission-id"
    else
        submission_output=$(xcrun notarytool "${notarytool_args[@]}" 2>&1) || {
            log_error "Notarization submission failed"
            echo "$submission_output"
            # Clean up zip if we created it
            [[ "$TARGET_TYPE" == "app" && -f "$submit_path" ]] && rm -f "$submit_path"
            return 1
        }
        echo "$submission_output"
    fi

    # Clean up temporary zip
    if [[ "$TARGET_TYPE" == "app" && -f "$submit_path" ]]; then
        rm -f "$submit_path"
    fi

    # Check if notarization was successful
    if [[ "$DRY_RUN" != "true" ]] && [[ "$SKIP_STAPLE" != "true" ]]; then
        if echo "$submission_output" | grep -qi "status: Accepted"; then
            log_success "Notarization accepted by Apple"
        elif echo "$submission_output" | grep -qi "status: Invalid"; then
            log_error "Notarization rejected by Apple"
            log_error "Run 'xcrun notarytool log <submission-id>' for details"
            return 1
        fi
    fi

    return 0
}

# =============================================================================
# Stapling
# =============================================================================

staple_target() {
    if [[ "$SKIP_STAPLE" == "true" ]]; then
        log_info "Skipping stapling (--skip-staple)"
        return 0
    fi

    log_info "Stapling notarization ticket..."

    run_cmd xcrun stapler staple "$TARGET_PATH"

    if [[ "$DRY_RUN" != "true" ]]; then
        # Verify stapling
        if xcrun stapler validate "$TARGET_PATH" 2>&1 | grep -q "valid"; then
            log_success "Notarization ticket stapled successfully"
        else
            log_warn "Could not verify stapling (this may be normal for some file types)"
        fi
    else
        log_success "Stapling completed (dry-run)"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    log_info "WinRun Code Signing & Notarization"
    echo ""

    validate_inputs

    local should_sign=true
    local should_notarize=true

    # Check signing credentials
    if ! check_signing_credentials; then
        should_sign=false
    fi

    # Check notarization credentials
    if ! check_notarization_credentials; then
        should_notarize=false
    fi

    echo ""

    # Exit early if nothing to do
    if [[ "$should_sign" != "true" && "$should_notarize" != "true" ]]; then
        log_warn "No credentials configured - nothing to do"
        log_warn "Set DEVELOPER_ID to enable code signing"
        log_warn "See --help for credential configuration"
        exit 0
    fi

    # Perform signing
    if [[ "$should_sign" == "true" ]]; then
        sign_target
    fi

    # Perform notarization
    if [[ "$should_notarize" == "true" ]]; then
        notarize_target
        staple_target
    fi

    echo ""
    echo "============================================"
    log_success "Code signing and notarization complete!"
    echo "============================================"
    echo ""
    echo "Target: ${TARGET_PATH}"
    echo "Signed: $([ "$should_sign" == "true" ] && echo "Yes" || echo "No")"
    echo "Notarized: $([ "$should_notarize" == "true" ] && echo "Yes" || echo "No")"
    echo ""

    if [[ "$should_sign" == "true" && "$should_notarize" != "true" ]]; then
        log_warn "App is signed but NOT notarized"
        log_warn "Users will see Gatekeeper warnings when opening the app"
        log_warn "Configure notarization credentials to enable notarization"
    fi
}

main "$@"
