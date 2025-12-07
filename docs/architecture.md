# WinRun Monorepo Architecture

## Repository Layout

```
host/                     Swift Package with daemon, app, CLI
  Package.swift
  Sources/
    WinRunShared/        Common configuration + logging
    WinRunXPC/           IPC contracts + async client
    WinRunVirtualMachine/Virtualization controller façade
    WinRunSpiceBridge/   Swift façade for Spice frame streaming
    WinRunDaemon/        `winrund` entry point
    WinRunApp/           AppKit UI shell for individual windows
    WinRunCLI/           `winrun` CLI implementation
  Tests/
    WinRunSharedTests    Sample XCTest target

guest/                   Windows/.NET code that runs inside VM
  WinRunAgent/           C# service orchestrating Spice + Win32 APIs
  WinRunAgent.Tests/     xUnit test project
  WinRunAgent.sln        Solution wiring both projects

apps/launchers/          macOS launcher templates referenced by CLI
infrastructure/launchd/  shipping plist for com.winrun.daemon
scripts/                 bootstrap + build helper scripts
docs/                    Additional documentation
```

## Build Targets

- **winrund (Swift)** — privileged daemon launched through LaunchDaemons. Wraps Virtualization.framework and exposes an XPC API for lifecycle + program execution calls.
- **WinRun.app (Swift/AppKit)** — lightweight per-window process that connects to Spice, renders, forwards input, and proxies clipboard/menus.
- **winrun CLI (Swift CLI)** — developer tooling for launching programs, managing configuration, creating launchers, and triggering setup.
- **WinRunAgent (C#)** — guest-side Windows service that enumerates windows, captures per-window surfaces, injects input, and reports metadata/shortcut events to the host via Spice custom channels.

## Cross-cutting Concerns

1. **IPC Contracts** — `WinRunXPC` contains strongly-typed request/response models reused by CLI, App, and daemon.
2. **Shared Resources** — `WinRunShared` defines config, logging, and error types consumed by every host target.
3. **Spice Streaming** — `WinRunSpiceBridge` abstracts the binding to libspice-glib. Current code provides a mock so development on Linux is still possible; replace with actual bridging before release.
4. **Virtual Machine Management** — `WinRunVirtualMachine` owns state transitions (start, stop, suspend) and resource accounting.
5. **Launcher Generation** — CLI exposes an ergonomic way to translate Windows shortcuts to `.app` bundles, mirroring the automation performed by the daemon when shortcuts are detected inside the guest.

## Build Flow

1. `scripts/bootstrap.sh` installs brew dependencies (Spice stack, pkg-config, etc.) and provisions the Application Support directory.
2. `swift build` (or `xcodebuild`) compiles host executables from `host/Package.swift`.
3. `dotnet build guest/WinRunAgent.sln` builds the guest Windows services and tests.
4. `scripts/build-all.sh` orchestrates both host + guest builds, automatically skipping guest build when `dotnet` is missing.

## Next Steps

- Flesh out the Spice bridge with the actual libspice-glib C shim.
- Replace mock window rendering in `WinRunApp` with Metal-backed view that consumes streamed frames.
- Implement real XPC listener in `WinRunDaemon` and integrate LaunchDaemon plist.
- Port the Windows agent to use Win32 hooks, Desktop Duplication, and Spice protocol extensions.
- Automate packaging (pkg + installer) via CI workflows.
