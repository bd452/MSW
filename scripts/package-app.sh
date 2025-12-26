#!/usr/bin/env bash
# =============================================================================
# package-app.sh - Build and assemble the complete WinRun.app bundle
# =============================================================================
#
# This script builds all Swift targets in release mode and assembles them into
# a distributable macOS app bundle with all required resources and dependencies.
#
# Usage:
#   ./scripts/package-app.sh [options]
#
# Options:
#   --output DIR      Output directory (default: build/WinRun.app)
#   --skip-build      Skip Swift build step (use existing binaries)
#   --skip-libs       Skip bundling Spice libraries
#   --msi PATH        Path to WinRunAgent.msi to bundle
#   --bundle-virtio   Download and bundle VirtIO drivers ISO (~500MB)
#   --virtio-iso PATH Use local VirtIO ISO instead of downloading
#   --help            Show this help message
#
# Environment variables:
#   BUILD_DIR         Build output directory (default: .build/release)
#   VIRTIO_ISO_URL    Override URL for VirtIO drivers ISO
#
# VirtIO Drivers:
#   By default, VirtIO drivers are NOT bundled to keep the app size small.
#   The app downloads drivers on-demand during Windows setup from:
#   https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
#
#   Use --bundle-virtio to include drivers in the bundle for offline use.
#
# =============================================================================

set -euo pipefail

SCRIPT_ROOT="$(cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_ROOT}/.." && pwd)"

# Default configuration
OUTPUT_DIR="${REPO_ROOT}/build/WinRun.app"
BUILD_DIR="${REPO_ROOT}/host/.build/release"
SKIP_BUILD=false
SKIP_LIBS=false
MSI_PATH=""
BUNDLE_VIRTIO=false
VIRTIO_ISO_PATH=""

# VirtIO drivers download configuration
# Using Fedora's stable VirtIO drivers for Windows
VIRTIO_DRIVERS_URL="${VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
VIRTIO_DRIVERS_SHA256_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso.sha256"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-libs)
            SKIP_LIBS=true
            shift
            ;;
        --msi)
            MSI_PATH="$2"
            shift 2
            ;;
        --bundle-virtio)
            BUNDLE_VIRTIO=true
            shift
            ;;
        --virtio-iso)
            VIRTIO_ISO_PATH="$2"
            BUNDLE_VIRTIO=true
            shift 2
            ;;
        --help)
            sed -n '1,/^# ===.*$/{ /^#/!d; s/^# //; s/^#$//; p; }' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
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

# =============================================================================
# Build Swift targets
# =============================================================================

build_host() {
    if [[ "$SKIP_BUILD" == "true" ]]; then
        log_info "Skipping build (--skip-build specified)"
        return
    fi

    log_info "Building Swift targets in release mode..."
    pushd "${REPO_ROOT}/host" >/dev/null

    swift build -c release

    popd >/dev/null
    log_success "Swift build completed"
}

# =============================================================================
# Create app bundle structure
# =============================================================================

create_bundle_structure() {
    log_info "Creating app bundle structure at ${OUTPUT_DIR}..."

    # Remove existing bundle if present
    if [[ -d "$OUTPUT_DIR" ]]; then
        rm -rf "$OUTPUT_DIR"
    fi

    # Create directory structure per operations.md
    mkdir -p "${OUTPUT_DIR}/Contents/MacOS"
    mkdir -p "${OUTPUT_DIR}/Contents/Resources/provision"
    mkdir -p "${OUTPUT_DIR}/Contents/Frameworks"
    mkdir -p "${OUTPUT_DIR}/Contents/Library/LaunchDaemons"

    log_success "Bundle structure created"
}

# =============================================================================
# Copy binaries
# =============================================================================

copy_binaries() {
    log_info "Copying binaries..."

    # Check that build outputs exist
    local binaries=("WinRunApp" "winrund" "winrun")
    for bin in "${binaries[@]}"; do
        if [[ ! -f "${BUILD_DIR}/${bin}" ]]; then
            log_error "Binary not found: ${BUILD_DIR}/${bin}"
            log_error "Run without --skip-build or ensure binaries are built."
            exit 1
        fi
    done

    # Copy main app binary (renamed to WinRun for the bundle)
    cp "${BUILD_DIR}/WinRunApp" "${OUTPUT_DIR}/Contents/MacOS/WinRun"

    # Copy daemon and CLI binaries
    cp "${BUILD_DIR}/winrund" "${OUTPUT_DIR}/Contents/MacOS/winrund"
    cp "${BUILD_DIR}/winrun" "${OUTPUT_DIR}/Contents/MacOS/winrun"

    # Make all binaries executable
    chmod +x "${OUTPUT_DIR}/Contents/MacOS/"*

    log_success "Binaries copied"
}

# =============================================================================
# Copy Info.plist and resources
# =============================================================================

copy_plist_and_resources() {
    log_info "Copying Info.plist and resources..."

    # Copy Info.plist from app resources
    local plist_src="${REPO_ROOT}/host/Sources/WinRunApp/Resources/AppInfo.plist"
    if [[ -f "$plist_src" ]]; then
        cp "$plist_src" "${OUTPUT_DIR}/Contents/Info.plist"

        # Update CFBundleExecutable to match the renamed binary
        /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable WinRun" "${OUTPUT_DIR}/Contents/Info.plist" 2>/dev/null || true
    else
        log_warn "AppInfo.plist not found, creating minimal Info.plist"
        cat > "${OUTPUT_DIR}/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.winrun.app</string>
    <key>CFBundleName</key>
    <string>WinRun</string>
    <key>CFBundleExecutable</key>
    <string>WinRun</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
</dict>
</plist>
EOF
    fi

    # Copy app icon if it exists
    local icon_src="${REPO_ROOT}/host/Sources/WinRunApp/Resources/AppIcon.icns"
    if [[ -f "$icon_src" ]]; then
        cp "$icon_src" "${OUTPUT_DIR}/Contents/Resources/AppIcon.icns"
        # Update Info.plist to reference the icon
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${OUTPUT_DIR}/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "${OUTPUT_DIR}/Contents/Info.plist" 2>/dev/null || true
    else
        log_warn "AppIcon.icns not found, app will use default icon"
    fi

    log_success "Info.plist and resources copied"
}

# =============================================================================
# Copy provisioning assets
# =============================================================================

copy_provisioning_assets() {
    log_info "Copying provisioning assets..."

    # Copy autounattend.xml
    local autounattend_src="${REPO_ROOT}/infrastructure/windows/autounattend.xml"
    if [[ -f "$autounattend_src" ]]; then
        cp "$autounattend_src" "${OUTPUT_DIR}/Contents/Resources/autounattend.xml"
        log_success "autounattend.xml copied"
    else
        log_warn "autounattend.xml not found"
    fi

    # Copy provisioning scripts
    local provision_dir="${REPO_ROOT}/infrastructure/windows/provision"
    if [[ -d "$provision_dir" ]]; then
        local scripts=("provision.ps1" "install-drivers.ps1" "install-agent.ps1" "optimize-windows.ps1" "finalize.ps1")
        local copied=0
        for script in "${scripts[@]}"; do
            if [[ -f "${provision_dir}/${script}" ]]; then
                cp "${provision_dir}/${script}" "${OUTPUT_DIR}/Contents/Resources/provision/${script}"
                ((copied++))
            fi
        done
        log_success "Provisioning scripts copied (${copied} files)"
    else
        log_warn "Provisioning directory not found: ${provision_dir}"
    fi

    # Copy MSI if provided
    if [[ -n "$MSI_PATH" && -f "$MSI_PATH" ]]; then
        cp "$MSI_PATH" "${OUTPUT_DIR}/Contents/Resources/WinRunAgent.msi"
        log_success "WinRunAgent.msi bundled"
    else
        log_warn "No MSI provided (use --msi to bundle WinRunAgent installer)"
    fi

    log_success "Provisioning assets copied"
}

# =============================================================================
# Handle VirtIO drivers
# =============================================================================

handle_virtio_drivers() {
    log_info "Configuring VirtIO drivers..."

    # Create a configuration file with the download URL for on-demand downloading
    local virtio_config="${OUTPUT_DIR}/Contents/Resources/virtio-config.plist"

    cat > "$virtio_config" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>VirtIODriversURL</key>
    <string>${VIRTIO_DRIVERS_URL}</string>
    <key>VirtIODriversSHA256URL</key>
    <string>${VIRTIO_DRIVERS_SHA256_URL}</string>
    <key>VirtIODriversBundled</key>
    <$([ "$BUNDLE_VIRTIO" == "true" ] && echo "true" || echo "false")/>
</dict>
</plist>
EOF

    log_success "VirtIO configuration created"

    # If bundling VirtIO drivers
    if [[ "$BUNDLE_VIRTIO" == "true" ]]; then
        local virtio_dest="${OUTPUT_DIR}/Contents/Resources/virtio-win.iso"

        # Use provided ISO path if available
        if [[ -n "$VIRTIO_ISO_PATH" && -f "$VIRTIO_ISO_PATH" ]]; then
            log_info "Copying VirtIO ISO from ${VIRTIO_ISO_PATH}..."
            cp "$VIRTIO_ISO_PATH" "$virtio_dest"
            log_success "VirtIO ISO bundled from local file"
        else
            # Download VirtIO drivers
            log_info "Downloading VirtIO drivers from Fedora..."
            log_info "URL: ${VIRTIO_DRIVERS_URL}"
            log_warn "This may take a while (~500MB download)"

            # Create temp file for download
            local temp_iso
            temp_iso=$(mktemp)

            if curl -L --progress-bar --fail -o "$temp_iso" "$VIRTIO_DRIVERS_URL"; then
                # Verify the download (basic size check)
                local file_size
                file_size=$(stat -f%z "$temp_iso" 2>/dev/null || stat -c%s "$temp_iso" 2>/dev/null || echo "0")
                if [[ "$file_size" -lt 100000000 ]]; then  # Less than 100MB is suspicious
                    log_error "Downloaded file seems too small (${file_size} bytes)"
                    rm -f "$temp_iso"
                    return 1
                fi

                mv "$temp_iso" "$virtio_dest"
                log_success "VirtIO drivers bundled ($(numfmt --to=iec "$file_size" 2>/dev/null || echo "${file_size} bytes"))"
            else
                log_error "Failed to download VirtIO drivers"
                rm -f "$temp_iso"
                log_warn "Continuing without bundled VirtIO drivers"
                log_warn "The app will download drivers on-demand during setup"
                # Update config to reflect drivers are not bundled
                /usr/libexec/PlistBuddy -c "Set :VirtIODriversBundled false" "$virtio_config" 2>/dev/null || true
            fi
        fi
    else
        log_info "VirtIO drivers will be downloaded on-demand during Windows setup"
        log_info "Use --bundle-virtio to include drivers in the bundle"
    fi
}

# =============================================================================
# Copy LaunchDaemon plist
# =============================================================================

copy_launchdaemon_plist() {
    log_info "Copying LaunchDaemon plist..."

    local plist_src="${REPO_ROOT}/infrastructure/launchd/com.winrun.daemon.plist"
    if [[ -f "$plist_src" ]]; then
        cp "$plist_src" "${OUTPUT_DIR}/Contents/Library/LaunchDaemons/com.winrun.daemon.plist"
        log_success "LaunchDaemon plist copied"
    else
        log_warn "LaunchDaemon plist not found: ${plist_src}"
    fi
}

# =============================================================================
# Bundle Spice libraries
# =============================================================================

bundle_spice_libraries() {
    if [[ "$SKIP_LIBS" == "true" ]]; then
        log_info "Skipping Spice library bundling (--skip-libs specified)"
        return
    fi

    log_info "Bundling Spice libraries..."

    # Find Homebrew prefix (works on both Intel and Apple Silicon)
    local brew_prefix
    if command -v brew >/dev/null 2>&1; then
        brew_prefix="$(brew --prefix)"
    elif [[ -d "/opt/homebrew" ]]; then
        brew_prefix="/opt/homebrew"
    elif [[ -d "/usr/local" ]]; then
        brew_prefix="/usr/local"
    else
        log_warn "Homebrew not found, skipping library bundling"
        return
    fi

    # List of required Spice libraries and their dependencies
    local spice_libs=(
        "libspice-client-glib-2.0"
        "libglib-2.0"
        "libgobject-2.0"
        "libgio-2.0"
        "libgmodule-2.0"
        "libgthread-2.0"
        "libintl"
        "libiconv"
        "libffi"
        "libpcre2-8"
    )

    local libs_copied=0
    for lib in "${spice_libs[@]}"; do
        # Look for the library in Homebrew lib directory
        local lib_file
        lib_file=$(find "${brew_prefix}/lib" -name "${lib}*.dylib" -type f 2>/dev/null | head -n1)

        if [[ -n "$lib_file" && -f "$lib_file" ]]; then
            # Resolve symlinks to get the actual file
            local actual_file
            actual_file=$(realpath "$lib_file" 2>/dev/null || readlink -f "$lib_file" 2>/dev/null || echo "$lib_file")

            # Copy the actual library file
            local dest_name
            dest_name=$(basename "$lib_file")
            cp "$actual_file" "${OUTPUT_DIR}/Contents/Frameworks/${dest_name}"
            ((libs_copied++))
        fi
    done

    if [[ $libs_copied -gt 0 ]]; then
        log_success "Spice libraries bundled (${libs_copied} libraries)"
        log_info "Note: Run install_name_tool to fix library paths before distribution"
    else
        log_warn "No Spice libraries found in ${brew_prefix}/lib"
        log_warn "Install spice-gtk via Homebrew: brew install spice-gtk"
    fi
}

# =============================================================================
# Fix library install names (for bundled distribution)
# =============================================================================

fix_library_paths() {
    if [[ "$SKIP_LIBS" == "true" ]]; then
        return
    fi

    local frameworks_dir="${OUTPUT_DIR}/Contents/Frameworks"
    local macos_dir="${OUTPUT_DIR}/Contents/MacOS"

    # Check if there are any libraries to fix
    if [[ ! -d "$frameworks_dir" ]] || [[ -z "$(ls -A "$frameworks_dir" 2>/dev/null)" ]]; then
        return
    fi

    log_info "Fixing library install names..."

    # Find Homebrew prefix for path replacement
    local brew_prefix
    if command -v brew >/dev/null 2>&1; then
        brew_prefix="$(brew --prefix)"
    elif [[ -d "/opt/homebrew" ]]; then
        brew_prefix="/opt/homebrew"
    else
        brew_prefix="/usr/local"
    fi

    # Fix each library in Frameworks
    for lib in "${frameworks_dir}"/*.dylib; do
        [[ -f "$lib" ]] || continue
        local lib_name
        lib_name=$(basename "$lib")

        # Change the library's own install name
        install_name_tool -id "@executable_path/../Frameworks/${lib_name}" "$lib" 2>/dev/null || true

        # Fix references to other bundled libraries
        for other_lib in "${frameworks_dir}"/*.dylib; do
            [[ -f "$other_lib" ]] || continue
            local other_name
            other_name=$(basename "$other_lib")

            # Replace Homebrew paths with @executable_path references
            install_name_tool -change \
                "${brew_prefix}/lib/${other_name}" \
                "@executable_path/../Frameworks/${other_name}" \
                "$lib" 2>/dev/null || true

            install_name_tool -change \
                "${brew_prefix}/opt/glib/lib/${other_name}" \
                "@executable_path/../Frameworks/${other_name}" \
                "$lib" 2>/dev/null || true
        done
    done

    # Fix the main executable's library references
    if [[ -f "${macos_dir}/WinRun" ]]; then
        for lib in "${frameworks_dir}"/*.dylib; do
            [[ -f "$lib" ]] || continue
            local lib_name
            lib_name=$(basename "$lib")

            install_name_tool -change \
                "${brew_prefix}/lib/${lib_name}" \
                "@executable_path/../Frameworks/${lib_name}" \
                "${macos_dir}/WinRun" 2>/dev/null || true
        done
    fi

    log_success "Library paths fixed"
}

# =============================================================================
# Create PkgInfo file
# =============================================================================

create_pkginfo() {
    log_info "Creating PkgInfo..."
    echo -n "APPL????" > "${OUTPUT_DIR}/Contents/PkgInfo"
    log_success "PkgInfo created"
}

# =============================================================================
# Validate bundle
# =============================================================================

validate_bundle() {
    log_info "Validating app bundle..."

    local errors=0

    # Check required files
    local required_files=(
        "Contents/Info.plist"
        "Contents/PkgInfo"
        "Contents/MacOS/WinRun"
        "Contents/MacOS/winrund"
        "Contents/MacOS/winrun"
    )

    for file in "${required_files[@]}"; do
        if [[ ! -f "${OUTPUT_DIR}/${file}" ]]; then
            log_error "Missing required file: ${file}"
            ((errors++))
        fi
    done

    # Check binaries are executable
    for bin in WinRun winrund winrun; do
        if [[ -f "${OUTPUT_DIR}/Contents/MacOS/${bin}" ]] && [[ ! -x "${OUTPUT_DIR}/Contents/MacOS/${bin}" ]]; then
            log_error "Binary not executable: ${bin}"
            ((errors++))
        fi
    done

    if [[ $errors -eq 0 ]]; then
        log_success "Bundle validation passed"
    else
        log_error "Bundle validation failed with ${errors} error(s)"
        return 1
    fi
}

# =============================================================================
# Print summary
# =============================================================================

print_summary() {
    echo ""
    echo "============================================"
    log_success "WinRun.app bundle created successfully!"
    echo "============================================"
    echo ""
    echo "Location: ${OUTPUT_DIR}"
    echo ""

    # Show bundle contents summary
    echo "Contents:"
    if command -v tree >/dev/null 2>&1; then
        tree -L 3 "$OUTPUT_DIR" 2>/dev/null || ls -laR "$OUTPUT_DIR"
    else
        find "$OUTPUT_DIR" -maxdepth 3 -print | sed 's|'"$OUTPUT_DIR"'||' | sort
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Test the app: open '${OUTPUT_DIR}'"
    echo "  2. Code sign:    codesign --deep --force --sign 'Developer ID' '${OUTPUT_DIR}'"
    echo "  3. Package DMG:  ./scripts/package-dmg.sh"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    log_info "WinRun App Bundle Packager"
    echo ""

    # Check we're on macOS
    if [[ "$(uname -s)" != "Darwin" ]]; then
        log_error "This script must be run on macOS"
        exit 1
    fi

    build_host
    create_bundle_structure
    copy_binaries
    copy_plist_and_resources
    copy_provisioning_assets
    handle_virtio_drivers
    copy_launchdaemon_plist
    bundle_spice_libraries
    fix_library_paths
    create_pkginfo
    validate_bundle
    print_summary
}

main "$@"
