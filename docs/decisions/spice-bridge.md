# Spice Bridge Integration Decisions

## Binding Strategy
- Wrap libspice-glib via a thin C shim compiled into the `WinRunSpiceBridge` Swift target so Swift code interacts with small, type-safe helpers instead of raw C APIs.
- Keep the shim focused on session management, buffer lifecycle, and callback forwarding; any Spice feature flags belong in Swift abstractions for easier testing.

## Transport Selection
- Prefer shared-memory (vhost-user) transports exposed by Virtualization.framework so pixel buffers never traverse the TCP stack; this keeps per-frame latency in the ~2–5 ms band noted in `SUMMARY.md`.
- The daemon publishes the shared-memory file descriptor (or its dup) to WinRun.app/CLI processes via XPC/env vars. Swift resolves this into a `Transport.sharedMemory` configuration which the C shim feeds into `spice_session_connect_with_fd`.
- TLS/TCP remains available as a fallback for development hosts that lack the shared-memory channel (e.g., Linux CI rigs) but is not the production path.
- Env binding: `WINRUN_SPICE_SHM_FD` points at the dup'd descriptor, while `WINRUN_SPICE_HOST/PORT/TLS` provide the legacy TCP settings for fallback or tests.

## Streaming Model
- Surface per-window frame and metadata streams through async delegate callbacks so host consumers (WinRun.app, CLI previews, future utilities) can subscribe independently.
- Normalize frame payloads into platform-neutral pixel buffers before handing them to AppKit/Metal to allow deterministic testing on non-macOS hosts.

## Per-Window Frame Buffer Architecture

### Rationale
Each Windows window gets its own independent frame buffer rather than sharing a single global buffer. This design:
- Allows independent frame rates per window (active window can update at 60fps while background windows stay static)
- Simplifies buffer management (no contention between windows for slots)
- Enables per-window memory optimization based on window size
- Supports dynamic allocation/deallocation as windows open/close

### Allocation Modes
The `FrameBufferMode` configuration (in `FrameStreamingConfig`) supports two strategies:

| Mode | Allocation Strategy | Reallocation Trigger | Use Case |
|------|---------------------|---------------------|----------|
| **Uncompressed** | Exact size for frame dimensions | Window resize | Low latency, higher memory (~33MB for 4K) |
| **Compressed** | Tranche buckets (3/8/20/50 MB) | Frame exceeds current tranche | Lower memory, higher latency |

**Design rationale**: For modern machines, a 33MB allocation for 4K is negligible. Uncompressed mode is the default for lowest latency. Compressed mode with LZ4 is available for memory-constrained scenarios but adds compression/decompression overhead.

### Buffer Structure (Guest Side)
```
PerWindowBufferManager
├── WindowFrameBuffer (window 1)
│   ├── Ring buffer with N slots (default: 3)
│   ├── FrameSlotHeader + pixel data per slot
│   └── Write/read indices for producer-consumer
├── WindowFrameBuffer (window 2)
│   └── ...
└── ...
```

Each `WindowFrameBuffer` manages:
- Memory allocation via `Marshal.AllocHGlobal`
- Ring buffer indices for pipelining
- Slot sizing based on allocation mode

### Protocol Messages
When a buffer is allocated or reallocated, the guest sends `WindowBufferAllocatedMessage`:
```
WindowBufferAllocatedMessage {
  windowId: UInt64       // Which window this buffer is for
  bufferPointer: UInt64  // Guest memory address of buffer
  bufferSize: Int32      // Total buffer size in bytes
  slotSize: Int32        // Size of each slot
  slotCount: Int32       // Number of slots (ring buffer capacity)
  isCompressed: Bool     // Whether frames will be LZ4 compressed
  isReallocation: Bool   // True if replacing an existing buffer
}
```

Frame notifications use the lightweight `FrameReadyMessage`:
```
FrameReadyMessage {
  windowId: UInt64    // Window the frame belongs to
  slotIndex: UInt32   // Which slot in the ring buffer
  frameNumber: UInt32 // Sequence number for ordering
  isKeyFrame: Bool    // Full frame vs delta (currently always true)
}
```

### Host-Side Routing
`SpiceFrameRouter` (host) handles:
1. Receiving `WindowBufferAllocatedMessage` → stores buffer info per window
2. Receiving `FrameReadyMessage` → routes to correct `SpiceWindowStream`
3. Managing `SharedFrameBufferReader` instances per window

### Frame Transfer Strategies

Two transfer strategies are supported, selectable via Settings UI:

#### Strategy A: Shared Memory (Zero-Copy)
**Default for production** - Lowest latency, no data copying.

1. VM configures shared memory region via Virtualization.framework
2. Guest allocates per-window buffers from shared region
3. Guest sends `WindowBufferAllocatedMessage` with offset into shared region
4. Host maps offset to host pointer, creates `SharedFrameBufferReader`
5. Guest sends `FrameReadyMessage` (lightweight notification)
6. Host reads frame data directly from mapped memory

**Requirements**: VM shared memory configuration (VZVirtioFileSystemDeviceConfiguration or similar)

#### Strategy B: Socket Transfer (Fallback)
**For development/fallback** - Works without shared memory, higher latency.

1. Guest captures frame and optionally compresses it
2. Guest sends frame data embedded in message over control channel
3. Host receives message, extracts frame bytes
4. Host creates `SharedFrame` directly from message payload

**Tradeoffs**: Copies data over socket, but works immediately without VM memory setup.

#### FrameTransferMode Configuration

```swift
enum FrameTransferMode {
    case sharedMemory  // Zero-copy via VM shared memory
    case socket        // Send frame data over control channel  
    case auto          // Try shared memory, fall back to socket
}
```

User selects mode in Settings UI. Default is `auto` which:
1. Attempts shared memory on startup
2. Falls back to socket if shared memory unavailable
3. Logs which mode is active

### Current Implementation Status

| Component | Status |
|-----------|--------|
| Per-window buffer allocation (guest) | ✅ Complete |
| WindowBufferAllocatedMessage protocol | ✅ Complete |
| FrameReadyMessage routing (host) | ✅ Complete |
| Strategy A: VM shared memory mapping | ❌ Not implemented |
| Strategy B: Socket frame transfer | ❌ Not implemented |
| FrameTransferMode configuration | ❌ Not implemented |
| Settings UI for mode selection | ❌ Not implemented |

### Deprecated: Single Shared Buffer
The original design used a single `SharedFrameBufferWriter`/`SharedFrameBufferReader` pair shared across all windows. This is now deprecated in favor of per-window buffers. Legacy code paths using `setFrameBufferReader(reader)` are marked `@available(*, deprecated)`.

## Resilience + Telemetry
- Implement reconnect/backoff policies for Spice channels; the UI must remain responsive when the guest agent crashes or restarts.
- Emit structured metrics (latency, dropped frames, reconnect counts) through the shared logging pipeline for observability.
- Guard against runaway timers by tying mock/test transports to explicit lifecycle events rather than global run loops.

## Key Files

### Guest (C#)
- `PerWindowFrameBuffer.cs` - `FrameBufferMode`, `PerWindowBufferConfig`, `WindowFrameBuffer`, `PerWindowBufferManager`
- `FrameStreamingService.cs` - Orchestrates capture loop, manages buffers, sends notifications
- `Messages.cs` - `WindowBufferAllocatedMessage`, `FrameReadyMessage`

### Host (Swift)
- `SpiceFrameRouter.swift` - Routes frame notifications to streams, stores buffer info
- `SharedFrameBuffer.swift` - `SharedFrameBufferReader`, buffer protocol types
- `SpiceControlChannel.swift` - Receives messages, delegates to router
- `SpiceWindowStream.swift` - Per-window stream, receives frames from router
