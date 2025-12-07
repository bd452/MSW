# Spice Bridge Integration Decisions

## Binding Strategy
- Wrap libspice-glib via a thin C shim compiled into the `WinRunSpiceBridge` Swift target so Swift code interacts with small, type-safe helpers instead of raw C APIs.
- Keep the shim focused on session management, buffer lifecycle, and callback forwarding; any Spice feature flags belong in Swift abstractions for easier testing.

## Transport Selection
- Prefer shared-memory (vhost-user) transports exposed by Virtualization.framework so pixel buffers never traverse the TCP stack; this keeps per-frame latency in the ~2–5 ms band noted in `SUMMARY.md`.
- The daemon publishes the shared-memory file descriptor (or its dup) to WinRun.app/CLI processes via XPC/env vars. Swift resolves this into a `Transport.sharedMemory` configuration which the C shim feeds into `spice_session_connect_with_fd`.
- TLS/TCP remains available as a fallback for development hosts that lack the shared-memory channel (e.g., Linux CI rigs) but is not the production path.
- Env binding: `WINRUN_SPICE_SHM_FD` points at the dup’d descriptor, while `WINRUN_SPICE_HOST/PORT/TLS` provide the legacy TCP settings for fallback or tests.

## Streaming Model
- Surface per-window frame and metadata streams through async delegate callbacks so host consumers (WinRun.app, CLI previews, future utilities) can subscribe independently.
- Normalize frame payloads into platform-neutral pixel buffers before handing them to AppKit/Metal to allow deterministic testing on non-macOS hosts.

## Resilience + Telemetry
- Implement reconnect/backoff policies for Spice channels; the UI must remain responsive when the guest agent crashes or restarts.
- Emit structured metrics (latency, dropped frames, reconnect counts) through the shared logging pipeline for observability.
- Guard against runaway timers by tying mock/test transports to explicit lifecycle events rather than global run loops.
