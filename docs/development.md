# Developer Guide

## Prerequisites

### macOS Host
- Xcode 15+
- Swift 5.9 toolchain
- Homebrew packages (`scripts/bootstrap.sh` handles install)
- libspice-glib development headers (installed via brew)
- (Optional) .NET 9 SDK for running guest linting locally: `brew install dotnet`

### Windows Guest
- Windows 11 ARM64 ISO (user-provided during first-run setup)
- .NET 9 SDK (pinned via `guest/global.json`) for agent development
- Visual Studio Build Tools or VS Code for testing

> **Recommended:** Windows 11 IoT Enterprise LTSC 2024 ARM64 for minimal bloat and 10-year support.
>
> **Note:** Apple Silicon Macs run ARM64 VMs natively. Windows 11 ARM64 includes Prism for x86/x64 app emulation. Windows Server does **not** include Prism — most Windows apps won't work on Server editions.

### Windows Version Compatibility

| Windows Version                     | x86/x64 Emulation | Bloat Level | Setup Warning        |
| ----------------------------------- | ----------------- | ----------- | -------------------- |
| Windows 11 IoT Enterprise LTSC 2024 | ✅ Full            | None        | ✅ Recommended        |
| Windows 11 Enterprise               | ✅ Full            | Low         | None                 |
| Windows 11 Pro/Home                 | ✅ Full            | High        | ⚠️ Bloatware detected |
| Windows Server 2022                 | ❌ None            | Low         | ⚠️ No x86/x64 apps    |
| Windows 10 ARM                      | ⚠️ x86 only        | Medium      | ⚠️ No 64-bit apps     |

> **Note:** Apple Silicon Macs run ARM64 VMs natively. Windows 11 ARM64 includes Prism for x86/x64 app emulation. Windows Server does not include Prism, making IoT Enterprise LTSC the required guest OS.

### SDK Version Strategy

The project uses a **split strategy** for maximum stability:

| Component                      | Version        | Why                                                  |
| ------------------------------ | -------------- | ---------------------------------------------------- |
| **SDK** (build tools)          | .NET 9         | Latest stable tooling, C# 13 features, faster builds |
| **Target Framework** (runtime) | net8.0-windows | LTS runtime (supported until Nov 2026)               |

This gives us modern development tooling while targeting a stable, long-term-supported runtime.

### SDK Version Pinning

The guest project uses `guest/global.json` to pin the .NET SDK version to **9.0.x**:

```json
{
  "sdk": {
    "version": "9.0.100",
    "rollForward": "latestFeature"
  }
}
```

This ensures:
- **Consistent analyzer behavior** between local development and CI
- **Reproducible builds** regardless of which SDKs are installed
- **Modern tooling** with C# 13 language features

#### Installing .NET 9 SDK

**macOS:**
```bash
brew install dotnet
```

**Windows:**
Download from https://dotnet.microsoft.com/download/dotnet/9.0

#### Verifying the SDK Version

From the `guest/` directory:
```bash
dotnet --version
# Should output 9.0.xxx
```

If you see a "compatible SDK not found" error, install .NET 9 SDK.

## Common Tasks

### Bootstrap the Repo
```
./scripts/bootstrap.sh
```

### Build Everything
```
./scripts/build-all.sh
```

### Build Host Artifacts Only
```
(cd host && swift build -c release)
```

> **Note:** Debug builds (`swift build`) use permissive authentication that allows unsigned clients and higher rate limits. Release builds (`swift build -c release`) enforce code signature verification and stricter throttling. See `XPCAuthenticationConfig` and `ThrottlingConfig` in `WinRunShared`.

### Build Guest Agent Only
```
(cd guest && dotnet build WinRunAgent.sln)
```

### Run Unit Tests
```
(cd host && swift test)
(cd guest && dotnet test WinRunAgent.sln)
```

## LaunchDaemon Installation

### Automated (Recommended)

After building the host components, run:
```bash
./scripts/bootstrap.sh --install-daemon
```

This will:
1. Copy the plist to `/Library/LaunchDaemons/`
2. Copy the `winrund` binary to `/usr/local/bin/`
3. Load (or reload) the daemon

To upgrade after rebuilding:
```bash
./scripts/bootstrap.sh --install-daemon  # Handles unload/reload automatically
```

To uninstall:
```bash
./scripts/bootstrap.sh --uninstall-daemon
```

### Manual Installation

If you prefer manual control:
1. Copy `infrastructure/launchd/com.winrun.daemon.plist` to `/Library/LaunchDaemons/`.
2. Copy the compiled `winrund` binary into `/usr/local/bin/`.
3. Load the daemon: `sudo launchctl bootstrap system /Library/LaunchDaemons/com.winrun.daemon.plist`.

To check daemon status:
```bash
sudo launchctl print system/com.winrun.daemon
```

## CLI Usage Examples
```
# Ensure the VM is alive and launch Notepad
host/.build/debug/winrun notepad.exe

# Query status
host/.build/debug/winrun vm status

# Generate launcher for calc.exe
host/.build/debug/winrun create-launcher "C:\\Windows\\System32\\calc.exe"
```

## Git Workflow

### Branch Strategy

- **`main`** — Always deployable; PRs merge here after review
- **Feature branches** — Created from `main` for each unit of work

### AI-Assisted Development

When using AI assistants (Cursor, etc.) to complete TODO.md items:

1. **One branch per chat session** — The AI creates a feature branch at session start and commits all work there
2. **Multiple TODO items → multiple commits** — Sequential TODO items within a session become separate commits on the same branch
3. **Session end** — Branch is ready for PR or manual review

This keeps history clean while allowing the AI to make incremental progress without branch sprawl.

### Manual Development

For human contributors:
1. Create a branch from `main`: `git checkout -b feat-my-feature`
2. Make commits with clear messages
3. Open a PR when ready for review
4. Squash-merge or rebase as appropriate

## Windows Agent Deployment
1. Build the solution on Windows ARM64: `dotnet publish -c Release -r win-arm64`.
2. Copy published bits to `C:\Program Files\WinRun`.
3. Register as Windows service using `sc create WinRunAgent binPath= "C:\Program Files\WinRun\WinRunAgent.exe" start= auto`.
4. Ensure Spice guest tools are installed so virtio-serial channels are available.

> **Architecture Note:** Use `win-arm64` for Apple Silicon Mac VMs. The .NET code is architecture-neutral, but the published output must match the guest OS architecture.

## Host Module Overview

The Swift host package contains several modules:

| Module                 | Purpose                                                   |
| ---------------------- | --------------------------------------------------------- |
| `WinRunShared`         | Configuration, logging, error types, input models         |
| `WinRunXPC`            | IPC contracts and async client for daemon communication   |
| `WinRunVirtualMachine` | VM lifecycle management via Virtualization.framework      |
| `WinRunSpiceBridge`    | Spice protocol binding and host↔guest messaging           |
| `WinRunSetup`          | Windows provisioning, ISO validation, setup orchestration |
| `WinRunDaemon`         | Background service entry point (`winrund`)                |
| `WinRunApp`            | AppKit app for rendering windows + setup wizard UI        |
| `WinRunCLI`            | Command-line interface (`winrun`)                         |

### WinRunSetup Module

The setup module handles first-run experience and Windows provisioning:

```
WinRunSetup/
├── ISOValidator.swift           # Validate Windows ISO, detect edition
├── WindowsEditionInfo.swift     # Edition metadata and compatibility checks
├── DiskImageCreator.swift       # Create sparse VM disk images
├── VMProvisioner.swift          # Drive unattended Windows installation
├── ProvisioningState.swift      # State machine for setup phases
├── SetupCoordinator.swift       # Orchestrate full setup flow
└── SetupError.swift             # Setup-specific error types
```

Key responsibilities:
- **ISO Validation**: Mount ISO, read install.wim/esd, detect ARM64 architecture and Windows edition
- **Edition Warnings**: Flag suboptimal ISOs (Windows Server lacks x86 emulation, consumer editions have bloat)
- **Provisioning**: Boot VM with ISO, drive unattended install, install drivers and agent
- **Progress Tracking**: Report phase-based progress to UI via async streams

### Testing Setup Components

```bash
# Run setup module tests
swift test --filter WinRunSetupTests

# Tests cover:
# - ISO metadata parsing (mock data)
# - Edition detection and warning generation
# - Provisioning state machine transitions
# - Disk image creation
# - Error recovery scenarios
```

## Testing Strategy

### What Requires Tests

Tests are required for:
1. **Code with downstream impact** — APIs used by other components, protocol contracts, shared data models
2. **Non-trivial logic** — State machines, parsers, serializers, validation, retry logic

#### Always Test
- Protocol message serialization/deserialization (the host↔guest contract)
- Configuration parsing and schema validation
- VM lifecycle state transitions
- Public APIs in `WinRunShared` and `WinRunXPC`
- Error handling for Spice/XPC operations

#### Usually Test
- Multi-branch business logic
- Data transformations (icon conversion, path translation)
- Timeout/backoff/reconnection logic

#### Skip Tests For
- Thin wrappers over platform APIs
- Build scripts and one-off tooling
- UI glue code with no logic

### Test Types

- **Unit tests** cover configuration helpers, CLI utilities, protocol messages, and guest data types. These run without external dependencies.
- **Integration tests** (future) will spin up a headless Windows VM locally by leveraging Virtualization.framework + qemu-img created disks.
- **End-to-end tests** (future) will run inside CI on macOS runners with nested virtualization enabled to validate Spice streaming.

### Running Tests

```bash
# All platforms (from repo root, requires macOS for host)
make test

# Host only (requires macOS)
make test-host
# Or directly:
cd host && swift test

# Guest only (requires .NET SDK)
make test-guest
# Or directly:
cd guest && dotnet test WinRunAgent.sln

# Remote execution (opt-in, via GitHub Actions)
make test-guest-remote   # REQUIRED for guest code changes (runs on Windows)
make test-host-remote    # run host tests on macOS remotely
make check-remote        # full CI remotely (host on macOS, guest on Windows)

# Linux-friendly (runs what works locally on Linux)
make check-linux         # lint both + guest build/test
```

### Test Organization

| Platform     | Framework | Test Location               | Naming         |
| ------------ | --------- | --------------------------- | -------------- |
| Host (Swift) | XCTest    | `host/Tests/<Module>Tests/` | `*Tests.swift` |
| Guest (C#)   | xUnit     | `guest/WinRunAgent.Tests/`  | `*Tests.cs`    |

### CI Integration

GitHub Actions enforces code quality on every PR:

| Workflow    | Platform | Checks                       |
| ----------- | -------- | ---------------------------- |
| `host.yml`  | macOS 14 | Build, Test, SwiftLint       |
| `guest.yml` | Windows  | Build, Test, `dotnet format` |

All checks must pass before merge. See [Branch Protection](#branch-protection) below.

## Linting & Formatting

### Available Commands

```bash
# Run all checks (lint + build + test) - use before committing
make check              # Full CI (requires macOS for host)
make check-linux        # Linux-friendly (lint both + guest build/test)

# Platform-specific checks (native)
make check-host         # SwiftLint + build + test (requires macOS)
make check-guest        # dotnet format + build + test

# Remote checks (opt-in, via GitHub Actions)
make check-host-remote  # Run host CI on macOS remotely
make check-remote       # Run full CI remotely (host on macOS, guest on Windows)

# Lint only (verify style)
make lint               # Both platforms
make lint-host          # SwiftLint --strict
make lint-guest         # dotnet format --verify-no-changes

# Format (auto-fix style issues)
make format             # Both platforms
make format-host        # SwiftLint --fix
make format-guest       # dotnet format
```

### Installing Linters

**macOS (host):**
```bash
brew install swiftlint
```

**Windows (guest):**
```bash
# dotnet format is included with .NET 8 SDK
dotnet tool list -g
```

### Configuration Files

| Platform     | Config File           | Tool          |
| ------------ | --------------------- | ------------- |
| Host (Swift) | `host/.swiftlint.yml` | SwiftLint     |
| Guest (C#)   | `guest/.editorconfig` | dotnet format |

### Pre-Commit Workflow

Before pushing changes, run the appropriate checks based on your environment:

**On macOS (full native checks):**
```bash
# For host code changes
make check-host

# For guest code changes
make check-guest          # Local lint + build (catches most issues)
git push                  # Push first — remote tests run against remote branch
make test-guest-remote    # REQUIRED: Tests on Windows CI (catches platform-specific issues)
```

**On Linux (or non-macOS environments like Cursor web agent):**
```bash
# Run everything that works locally
make check-linux          # Lint both + guest build/test

# For guest code changes, also run remote Windows tests
git push
make test-guest-remote    # REQUIRED: Tests on Windows CI

# For host code changes, run remote macOS tests
git push
make test-host-remote     # Runs build + test on macOS via GitHub Actions
```

**Important for Guest Code**: Always run `make test-guest-remote` after modifying guest code. This catches:
- Line ending issues (CRLF enforcement on Windows)
- Windows-specific test failures
- Platform-specific linting differences

**Important for Host Code on Non-macOS**: Use `make test-host-remote` to run host tests on macOS via GitHub Actions. Native host build/test requires macOS due to Apple framework dependencies (Virtualization.framework, AppKit, Metal).

**Remote tests run against the remote branch**: if you have local-only changes, push them first or the remote workflow won’t see them.

The `.gitattributes` file automatically normalizes line endings, but remote testing is still required to validate Windows-specific behavior.

## Branch Protection

To enforce CI checks before merge, configure branch protection in GitHub:

1. Go to **Settings → Branches → Add rule**
2. Branch name pattern: `main`
3. Enable:
   - ☑️ Require a pull request before merging
   - ☑️ Require status checks to pass before merging
   - ☑️ Require branches to be up to date before merging
4. Select required status checks:
   - `CI` (the final gate job that aggregates all results)
5. Save changes

> **Note:** Only require the `CI` job, not individual jobs. Individual jobs may be skipped when their files haven't changed, but the `CI` gate handles this correctly.

### Path-Based Triggers

CI jobs only run when relevant files change:

| Job | Triggered by changes in |
|-----|------------------------|
| Host Build & Test | `host/**`, `.github/workflows/ci.yml`, `.github/Brewfile.host-*` |
| Host Lint | `host/**`, `.github/workflows/ci.yml`, `.github/Brewfile.host-*` |
| Guest Build & Test | `guest/**`, `.github/workflows/ci.yml` |
| Guest Lint | `guest/**`, `.github/workflows/ci.yml` |

This saves CI minutes when changes are isolated to one platform. The final `CI` gate job treats skipped jobs as successful.
