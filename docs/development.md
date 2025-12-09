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
1. Copy `infrastructure/launchd/com.winrun.daemon.plist` to `/Library/LaunchDaemons/`.
2. Copy the compiled `winrund` binary into `/usr/local/bin/`.
3. Load the daemon: `sudo launchctl bootstrap system /Library/LaunchDaemons/com.winrun.daemon.plist`.

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
- **Unit tests** cover configuration helpers, CLI utilities, and guest data types.
- **Integration tests** (future) will spin up a headless Windows VM locally by leveraging Virtualization.framework + qemu-img created disks.
- **End-to-end tests** (future) will run inside CI on macOS runners with nested virtualization enabled to validate Spice streaming.
