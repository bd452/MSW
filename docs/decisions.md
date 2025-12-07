# Architecture Decisions

## Spice Bridge Integration
- Bind Swift to libspice-glib through a thin C shim compiled in the `WinRunSpiceBridge` target.
- Surface per-window frame + metadata streams over async delegates; the host app should remain platform agnostic.
- Expose guardrails for reconnect/backoff so the macOS UI does not wedge when the guest agent restarts.

## Virtualization Lifecycle + Metrics
- `VirtualMachineController` must own Virtualization.framework objects (VM, configuration, storage) and serialize state transitions.
- Suspend/resume logic should key off active Spice sessions; idle detection feeds LaunchDaemon power policies.
- Emit structured metrics (uptime, boot latency, session counts) into the shared logging stack for observability.

## Host/Guest Protocol Contracts
- All host<->guest control flows ride on XPC (host) and Spice custom channels (guest).
- Shared Swift models (WinRunXPC) and guest C# DTOs must stay schema-compatible; introduce version negotiation before breaking fields.
- Metadata payloads carry window bounds, display DPI, icon hashes, and capability flags to negotiate advanced features (clipboard, menus, drag/drop).

## Packaging, Documentation, and CI
- Treat `scripts/bootstrap.sh` + `scripts/build-all.sh` as the single source of truth for dependency install and build orchestration.
- CI should run both host SwiftPM jobs (macOS runners) and guest dotnet workflows (Windows runners) before packaging artifacts.
- Documentation (`README`, `docs/architecture.md`, `docs/development.md`) must describe the productionized pipeline so new contributors understand the expectations.
