# Spice Bridge Integration Decisions

## Binding Strategy
- Wrap libspice-glib via a thin C shim compiled into the `WinRunSpiceBridge` Swift target so Swift code interacts with small, type-safe helpers instead of raw C APIs.
- Keep the shim focused on session management, buffer lifecycle, and callback forwarding; any Spice feature flags belong in Swift abstractions for easier testing.

## Streaming Model
- Surface per-window frame and metadata streams through async delegate callbacks so host consumers (WinRun.app, CLI previews, future utilities) can subscribe independently.
- Normalize frame payloads into platform-neutral pixel buffers before handing them to AppKit/Metal to allow deterministic testing on non-macOS hosts.

## Resilience + Telemetry
- Implement reconnect/backoff policies for Spice channels; the UI must remain responsive when the guest agent crashes or restarts.
- Emit structured metrics (latency, dropped frames, reconnect counts) through the shared logging pipeline for observability.
- Guard against runaway timers by tying mock/test transports to explicit lifecycle events rather than global run loops.
