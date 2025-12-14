# WinRun Monorepo Architecture

## Overview

WinRun provides a seamless Windows-on-macOS experience, allowing users to run Windows applications as native-feeling macOS windows. The system uses Apple's Virtualization.framework to run Windows ARM64 in a lightweight VM, with the Spice protocol handling display streaming and input forwarding.

## Repository Layout

```
host/                        Swift Package with daemon, app, CLI, setup
  Package.swift
  Sources/
    WinRunShared/           Common configuration + logging
    WinRunXPC/              IPC contracts + async client
    WinRunVirtualMachine/   Virtualization controller façade
    WinRunSpiceBridge/      Swift façade for Spice frame streaming
    WinRunSetup/            Windows provisioning + setup orchestration
    WinRunDaemon/           `winrund` entry point
    WinRunApp/              AppKit UI shell for windows + setup wizard
    WinRunCLI/              `winrun` CLI implementation
  Tests/
    WinRunSharedTests/      Shared library tests
    WinRunSpiceBridgeTests/ Protocol + bridge tests
    WinRunVirtualMachineTests/ VM controller tests
    WinRunSetupTests/       Provisioning tests
    WinRunAppTests/         App + setup UI tests

guest/                      Windows/.NET code that runs inside VM
  WinRunAgent/              C# service orchestrating Spice + Win32 APIs
  WinRunAgent.Tests/        xUnit test project
  WinRunAgent.Installer/    WiX MSI installer project
  WinRunAgent.sln           Solution wiring all projects

infrastructure/
  launchd/                  Shipping plist for com.winrun.daemon
  windows/                  Windows provisioning assets
    autounattend.xml        Unattended Windows installation answers
    provision/              Post-install PowerShell scripts

apps/launchers/             macOS launcher templates referenced by CLI
scripts/                    Bootstrap, build, packaging scripts
docs/                       Architecture and decision documentation
```

## Build Targets

- **winrund (Swift)** — Privileged daemon launched through LaunchDaemons. Wraps Virtualization.framework and exposes an XPC API for lifecycle + program execution calls.
- **WinRun.app (Swift/AppKit)** — Per-window process that connects to Spice, renders frames, forwards input, and proxies clipboard/menus. Also contains the first-run setup wizard.
- **winrun CLI (Swift CLI)** — Developer tooling for launching programs, managing configuration, creating launchers, and triggering setup.
- **WinRunAgent (C#)** — Guest-side Windows service that enumerates windows, captures per-window surfaces, injects input, and reports metadata/shortcut events to the host via Spice custom channels.
- **WinRunAgent.msi** — Windows installer package for deploying the agent during provisioning.

## System Architecture

### End-to-End Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              macOS Host                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐    XPC    ┌──────────────┐                                │
│  │ WinRun.app   │◄─────────►│   winrund    │                                │
│  │ (per window) │           │  (daemon)    │                                │
│  └──────┬───────┘           └──────┬───────┘                                │
│         │                          │                                         │
│         │ Spice                    │ Virtualization.framework               │
│         │                          │                                         │
│         ▼                          ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     Windows ARM64 VM                                 │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                  │    │
│  │  │ Notepad.exe │  │  calc.exe   │  │  Other apps │                  │    │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘                  │    │
│  │         │                │                │                          │    │
│  │         ▼                ▼                ▼                          │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │                    WinRunAgent Service                       │    │    │
│  │  │  • Window tracking (EnumWindows, SetWinEventHook)           │    │    │
│  │  │  • Frame capture (Desktop Duplication API)                  │    │    │
│  │  │  • Input injection (SendInput)                              │    │    │
│  │  │  • Icon extraction + shortcut sync                          │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  │                              │                                       │    │
│  │                              │ Spice Agent Protocol                  │    │
│  │                              ▼                                       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Cross-cutting Concerns

1. **IPC Contracts** — `WinRunXPC` contains strongly-typed request/response models reused by CLI, App, and daemon.

2. **Shared Resources** — `WinRunShared` defines config, logging, error types, authentication policies, and rate limiting consumed by every host target.

3. **Spice Streaming** — `WinRunSpiceBridge` abstracts the binding to libspice-glib and defines the host↔guest protocol:
   - `SpiceProtocol.swift`: Protocol version constants, message types enum, guest capabilities flags
   - `SpiceGuestMessages.swift`: Guest→host message types (metadata, frames, heartbeat, provisioning progress)
   - `SpiceHostMessages.swift`: Host→guest message types (launch, input, clipboard, etc.)
   - `SpiceMessageSerializer.swift`: Binary envelope serialization `[Type:1][Length:4][Payload:N]`

4. **Virtual Machine Management** — `WinRunVirtualMachine` owns state transitions (start, stop, suspend) and resource accounting.

5. **Setup & Provisioning** — `WinRunSetup` handles first-run experience:
   - ISO validation and Windows edition detection
   - Disk image creation
   - Unattended Windows installation orchestration
   - Post-install driver and agent deployment
   - Progress tracking and error recovery

6. **Launcher Generation** — CLI exposes an ergonomic way to translate Windows shortcuts to `.app` bundles, mirroring the automation performed by the daemon when shortcuts are detected inside the guest.

7. **XPC Security** — The daemon authenticates all XPC connections via code signature verification and Unix group membership, then applies per-client request throttling to prevent abuse. See `docs/decisions/protocols.md` for implementation details.

8. **Protocol Versioning** — Host and guest negotiate protocol compatibility during initial handshake via `CapabilityFlags` message. Version 1.0 is current; see `docs/decisions/protocols.md` for version compatibility rules.

## Setup & Provisioning Flow

### First-Run Experience

When a user launches WinRun.app without an existing Windows VM:

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. WELCOME                                                       │
│    "To run Windows apps, you need Windows 11 ARM64"             │
│    [Link to Microsoft download]                                  │
│    Recommendation: Windows 11 IoT Enterprise LTSC 2024          │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. ISO IMPORT                                                    │
│    ┌─────────────────────────────────────────┐                  │
│    │  Drop Windows ISO here or click browse  │                  │
│    └─────────────────────────────────────────┘                  │
│    Validation: ARM64 check, edition detection, warnings         │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. INSTALLATION (10-15 minutes, automated)                       │
│    ✓ Creating disk image                                        │
│    ✓ Installing Windows (unattended)                            │
│    → Installing drivers                                         │
│    ○ Installing WinRun Agent                                    │
│    ○ Optimizing Windows                                         │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. READY                                                         │
│    "WinRun is ready! Drag any .exe to run it."                  │
│    Quick-start tips and getting started guide                    │
└─────────────────────────────────────────────────────────────────┘
```

### Windows Version Recommendations

| Version                                   | x86/x64 Emulation | Bloat  | Recommended               |
| ----------------------------------------- | ----------------- | ------ | ------------------------- |
| Windows 11 IoT Enterprise LTSC 2024 ARM64 | ✅ Full            | None   | ⭐ Primary                 |
| Windows 11 Enterprise ARM64               | ✅ Full            | Low    | Good                      |
| Windows 11 Pro/Home ARM64                 | ✅ Full            | High   | Acceptable (with warning) |
| Windows Server 2022 ARM64                 | ❌ None            | Low    | ⚠️ No x86 apps             |
| Windows 10 ARM64                          | ⚠️ x86 only        | Medium | ⚠️ No x64 apps             |

### Provisioning Components

```
infrastructure/windows/
├── autounattend.xml           # Unattended install configuration
└── provision/
    ├── install-drivers.ps1    # VirtIO drivers
    ├── install-agent.ps1      # WinRunAgent.msi deployment
    ├── optimize-windows.ps1   # Remove bloat, disable services
    └── finalize.ps1           # Signal completion, create snapshot
```

## App Bundle Structure

The distributed WinRun.app contains all components needed for operation:

```
WinRun.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   ├── WinRun              # Main app binary
│   │   ├── winrund             # Daemon (installed on first run)
│   │   └── winrun              # CLI tool
│   ├── Resources/
│   │   ├── AppIcon.icns
│   │   ├── autounattend.xml
│   │   ├── provision/          # PowerShell scripts
│   │   └── WinRunAgent.msi     # Guest agent installer
│   ├── Frameworks/
│   │   ├── libspice-glib.dylib
│   │   └── ... (dependencies)
│   └── Library/
│       └── LaunchDaemons/
│           └── com.winrun.daemon.plist
```

## Build Flow

1. `scripts/bootstrap.sh` installs brew dependencies (Spice stack, pkg-config, etc.) and provisions the Application Support directory.
2. `swift build` (or `xcodebuild`) compiles host executables from `host/Package.swift`.
3. `dotnet build guest/WinRunAgent.sln` builds the guest Windows services and tests.
4. `scripts/build-guest-installer.ps1` (on Windows) creates WinRunAgent.msi.
5. `scripts/build-all.sh` orchestrates both host + guest builds.
6. `scripts/package-app.sh` assembles the complete WinRun.app bundle.
7. `scripts/sign-and-notarize.sh` signs and notarizes for distribution.
8. `scripts/package-dmg.sh` creates the final distributable DMG.

## Data Storage

```
~/Library/Application Support/WinRun/
├── config.json                 # User configuration
├── windows.img                 # Windows VM disk image (~4-10GB)
├── windows.vmstate             # Suspended VM state (for fast resume)
└── cache/
    └── icons/                  # Cached Windows app icons
```

## Security Model

1. **VM Isolation**: Windows runs in a sandboxed VM via Virtualization.framework
2. **XPC Authentication**: Daemon verifies client code signatures
3. **No Network Bypass**: All network traffic goes through VM NAT
4. **Minimal Privileges**: App runs as user, daemon as root only for VM management
