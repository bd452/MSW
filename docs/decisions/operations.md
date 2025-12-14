# Operations, Packaging, and CI Decisions

## Script Ownership
- Treat `scripts/bootstrap.sh` and `scripts/build-all.sh` as the single source of truth for dependency installation and build orchestration.
- Any new packaging steps must be implemented as reusable scripts (e.g., `scripts/package-app.sh`, `scripts/package-dmg.sh`) and then invoked from `build-all.sh` or CI.

## Packaging Targets

### macOS Host (WinRun.app)

The distributed app bundle contains all components needed for operation:

```
WinRun.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   ├── WinRun                    # Main app binary
│   │   ├── winrund                   # Daemon binary (installed on first run)
│   │   └── winrun                    # CLI tool
│   ├── Resources/
│   │   ├── AppIcon.icns
│   │   ├── autounattend.xml          # Windows unattended install
│   │   ├── provision/                # PowerShell provisioning scripts
│   │   │   ├── install-drivers.ps1
│   │   │   ├── install-agent.ps1
│   │   │   ├── optimize-windows.ps1
│   │   │   └── finalize.ps1
│   │   └── WinRunAgent.msi           # Guest agent installer
│   ├── Frameworks/
│   │   ├── libspice-glib.dylib       # Bundled Spice libraries
│   │   ├── libglib-2.0.dylib
│   │   └── ... (other dependencies)
│   └── Library/
│       └── LaunchDaemons/
│           └── com.winrun.daemon.plist
```

**Packaging scripts:**
- `scripts/package-app.sh` — Assembles the complete .app bundle
- `scripts/sign-and-notarize.sh` — Code signs and notarizes with Apple
- `scripts/package-dmg.sh` — Creates distributable DMG with drag-to-Applications

### Windows Guest (WinRunAgent.msi)

The guest agent is packaged as an MSI for automated deployment during Windows provisioning:

```
WinRunAgent.msi
├── WinRunAgent.exe           # Main service binary
├── Dependencies/             # .NET runtime dependencies
└── Service registration      # Installs as auto-start Windows service
```

**Packaging scripts:**
- `scripts/build-guest-installer.ps1` — Builds MSI using WiX toolset (runs on Windows)

## Code Signing & Notarization

### macOS Requirements

For distribution outside the App Store:

1. **Developer ID Certificate** — Required for Gatekeeper approval
2. **Notarization** — Apple scans the binary for malware
3. **Stapling** — Attach notarization ticket to app bundle

```bash
# Sign the app bundle
codesign --deep --force --verify --verbose \
    --sign "Developer ID Application: Your Name (TEAM_ID)" \
    --options runtime \
    WinRun.app

# Notarize with Apple
xcrun notarytool submit WinRun.dmg \
    --apple-id "developer@example.com" \
    --team-id TEAM_ID \
    --password "@keychain:AC_PASSWORD" \
    --wait

# Staple the ticket
xcrun stapler staple WinRun.app
xcrun stapler staple WinRun.dmg
```

### Bundled Dependencies

The app bundle must include all dynamic libraries:

- libspice-glib-2.0.dylib
- libspice-client-glib-2.0.dylib
- libglib-2.0.dylib
- libgobject-2.0.dylib
- libgio-2.0.dylib
- And their transitive dependencies

Use `install_name_tool` to fix library paths for bundling:

```bash
# Update library paths to use @executable_path
install_name_tool -change \
    /opt/homebrew/lib/libspice-glib-2.0.dylib \
    @executable_path/../Frameworks/libspice-glib-2.0.dylib \
    WinRun.app/Contents/MacOS/WinRun
```

## Distribution Channels

### Primary: Direct Download (DMG)

- Host DMG on GitHub Releases or dedicated website
- DMG includes drag-to-Applications layout
- Background image with instructions
- Signed and notarized for Gatekeeper

### Secondary: Homebrew Cask

```ruby
cask "winrun" do
  version "1.0.0"
  sha256 "abc123..."
  url "https://github.com/winrun/winrun/releases/download/v#{version}/WinRun-#{version}.dmg"
  name "WinRun"
  desc "Run Windows apps seamlessly on macOS"
  homepage "https://winrun.dev"
  app "WinRun.app"
end
```

## Documentation Expectations

- `README.md` — User-facing installation and quick start guide
- `docs/architecture.md` — System design and component interaction
- `docs/development.md` — Build, test, and deployment workflows for contributors
- `docs/decisions/` — Architecture Decision Records (ADRs) for significant choices

All documentation must describe the production pipeline:
1. Bootstrap → Install dependencies and prepare environment
2. Build → Compile host and guest components
3. Package → Assemble app bundle with all resources
4. Sign → Code sign and notarize
5. Distribute → Create DMG and upload to release

## Continuous Integration

### CI Workflow Structure

```yaml
# .github/workflows/ci.yml
jobs:
  host-build:
    runs-on: macos-14
    steps:
      - Build Swift targets
      - Run SwiftLint
      - Run host tests

  host-package:
    runs-on: macos-14
    needs: host-build
    steps:
      - Build release binaries
      - Assemble app bundle
      - Sign and notarize (on release tags)
      - Create DMG
      - Upload artifact

  guest-build:
    runs-on: windows-latest
    steps:
      - Build .NET solution
      - Run dotnet format
      - Run guest tests

  guest-package:
    runs-on: windows-latest
    needs: guest-build
    steps:
      - Build MSI installer
      - Upload artifact

  release:
    if: startsWith(github.ref, 'refs/tags/')
    needs: [host-package, guest-package]
    steps:
      - Download all artifacts
      - Create GitHub Release
      - Upload DMG and MSI
```

### Branch Protection

Required status checks before merge:
- Host Build & Test (macOS)
- Host Lint (SwiftLint)
- Guest Build & Test (Windows)
- Guest Lint (dotnet format)

### Artifact Retention

- Development builds: 7 days
- Release builds: Permanent (attached to GitHub Release)
- Test results: 30 days

## VirtIO Drivers Strategy

VirtIO drivers are required for Windows to communicate with virtualized hardware.

**Options:**
1. **Bundle in app bundle** (~50MB) — Immediate availability, larger download
2. **Download on demand** — Smaller app, requires internet during setup
3. **Reference stable URL** — Point to Fedora's virtio-win releases

**Recommendation:** Download on demand with bundled fallback URL and local caching.

Source: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/

## Auto-Updates (Future)

Consider integrating Sparkle for automatic updates:

```xml
<!-- Info.plist -->
<key>SUFeedURL</key>
<string>https://winrun.dev/appcast.xml</string>
```

This allows users to receive updates without manually downloading new versions.
