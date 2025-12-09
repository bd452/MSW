# Developer Guide

## Prerequisites

### macOS Host
- Xcode 15+
- Swift 5.9 toolchain
- Homebrew packages (`scripts/bootstrap.sh` handles install)
- libspice-glib development headers (installed via brew)

### Windows Guest
- Windows Server 2022 (Desktop Experience disabled)
- .NET 8 SDK
- Visual Studio Build Tools (for testing the agent)

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

## Windows Agent Deployment
1. Build the solution on Windows: `dotnet publish -c Release -r win-x64`.
2. Copy published bits to `C:\Program Files\WinRun`.
3. Register as Windows service using `sc create WinRunAgent binPath= "C:\Program Files\WinRun\WinRunAgent.exe" start= auto`.
4. Ensure Spice guest tools are installed so virtio-serial channels are available.

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
# All platforms (from repo root)
make test-host test-guest

# Host only (macOS, requires Xcode)
cd host && swift test

# Guest only (Windows or cross-platform .NET SDK)
cd guest && dotnet test WinRunAgent.sln
```

### Test Organization

| Platform | Framework | Test Location | Naming |
|----------|-----------|---------------|--------|
| Host (Swift) | XCTest | `host/Tests/<Module>Tests/` | `*Tests.swift` |
| Guest (C#) | xUnit | `guest/WinRunAgent.Tests/` | `*Tests.cs` |

### CI Integration

When GitHub Actions workflows are added:
- `host.yml` runs `swift test` on macOS runners
- `guest.yml` runs `dotnet test` on Windows runners
- All tests must pass for PR merge
- Test results and coverage are published as artifacts
