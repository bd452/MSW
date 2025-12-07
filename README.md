# WinRun Monorepo

WinRun delivers seamless Windows application windows on macOS using Virtualization.framework and the Spice remote display stack. This repository is a fully-structured monorepo that houses every component needed to build the experience end-to-end: the privileged macOS daemon (`winrund`), the GUI app wrapper (`WinRun.app`), the CLI (`winrun`), launcher templates, infrastructure assets, and the Windows guest agent.

## Layout

```
├── host/                 # Swift Package containing all macOS targets
├── guest/                # Windows/.NET guest agent code
├── apps/launchers/       # Resources for generated macOS .app launchers
├── infrastructure/       # LaunchDaemon plist and future packaging bits
├── scripts/              # Bootstrap + build helpers
└── docs/                 # Architecture & development guides
```

See `docs/architecture.md` for a deeper component breakdown.

## Getting Started

1. **Install prerequisites** (macOS): run `./scripts/bootstrap.sh` to pull down Homebrew dependencies and prep the Application Support directory.
2. **Build everything:** `./scripts/build-all.sh`. The script compiles host Swift targets and, when `dotnet` is available, the guest Windows agent.
3. **Read the guides:**
   - `docs/architecture.md` — how each module fits together.
   - `docs/development.md` — day-to-day workflows, build/test commands, and deployment steps.

## Key Components

- **winrund (Swift daemon)** — Manages Windows VM lifecycle, exposes XPC, interfaces with LaunchDaemon, and coordinates Spice shared-memory transports.
- **WinRun.app (Swift/AppKit)** — One instance per Windows window. Renders Spice frames, keeps NSWindow metadata in sync, and forwards input/clipboard events.
- **winrun CLI (Swift CLI)** — Power-user tooling for launching programs, managing VM state, configuring resources, and creating `.app` launchers.
- **WinRunAgent (C#)** — Guest-side Windows service built on .NET 8. Tracks window metadata, captures per-window frames, forwards events over Spice channels, and notifies the host about shortcut installations and icon extraction.

## Monorepo Principles

- **Shared Swift modules** (`WinRunShared`, `WinRunXPC`, `WinRunVirtualMachine`, `WinRunSpiceBridge`) provide reusable configuration, IPC models, and virtualization helpers consumed by all host executables.
- **Single source of truth for infrastructure** — LaunchDaemon plist, bootstrap scripts, and launcher templates live alongside the code they configure.
- **Language-appropriate tooling** — Swift Package Manager for macOS targets, dotnet/Visual Studio solution for Windows agent, shell scripts for automation, and Markdown for documentation.

## Next Steps

- Replace mock Spice bridge + VM controller implementations with production bindings.
- Flesh out the WinRun guest agent with real Win32 hooks, Desktop Duplication, and Spice protocol extensions described in the architecture.
- Add CI workflows targeting macOS (host) and Windows (guest) to gate pull requests.
- Integrate installer packaging (pkg + MSI) for host and guest artifacts respectively.

Contributions welcome—open issues and PRs to discuss design decisions or propose enhancements.
