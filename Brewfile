# WinRun Homebrew Dependencies
#
# ⚠️  DO NOT use `brew install/upgrade/remove` directly!
#     Use `make brew-sync` to manage dependencies.
#     This keeps Brewfile.lock in sync for CI caching.
#
# Workflow:
#   - Add package:    Edit this file, then run `make brew-sync`
#   - Remove package: Edit this file, then run `make brew-sync`
#   - Upgrade all:    Run `make brew-sync`
#   - Then commit both Brewfile and Brewfile.lock

# Build dependencies
brew "spice-gtk"
brew "pkgconf"
brew "cmake"
brew "ninja"
brew "glib"
brew "spice-protocol"
brew "wimlib"

# Runtime dependencies (Windows installation)
brew "qemu"       # qemu-system-aarch64 for Windows installation VM
brew "swtpm"      # Software TPM 2.0 emulator (required by Windows 11)

# Development tools
brew "swiftlint"
