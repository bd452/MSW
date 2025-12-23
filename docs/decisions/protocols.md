# Host ↔ Guest Protocol Decisions

## Transport Layer
- Control flows originate from macOS targets via XPC and terminate in the daemon, which relays commands to the guest over custom Spice channels.
- Guest components expose symmetrical handlers that parse the shared payload schema and respond with acknowledgements plus telemetry.
- Spice channels use a binary envelope format: `[Type:1][Length:4][Payload:N]` where payload is JSON-encoded.

## Protocol Version (Implemented)

The protocol uses semantic versioning to ensure host↔guest compatibility:

- **Version format**: Combined 32-bit value with upper 16 bits = major, lower 16 bits = minor
- **Current version**: 1.0 (`0x00010000`)
- **Compatibility rules**:
  - Major version must match exactly
  - Host can communicate with guests having equal or older minor versions
  - Minor version increments for backwards-compatible additions
  - Major version increments for breaking changes

Version negotiation occurs during the initial handshake when the guest sends a `CapabilityFlags` message containing its protocol version and supported capabilities.

## Guest Capabilities (Implemented)

The guest agent advertises its capabilities during handshake using the `GuestCapabilities` flags:

| Capability | Flag | Description |
|------------|------|-------------|
| WindowTracking | 0x01 | Can enumerate and track window lifecycle events |
| DesktopDuplication | 0x02 | Can capture window frames via DXGI |
| ClipboardSync | 0x04 | Can synchronize clipboard bidirectionally |
| DragDrop | 0x08 | Supports drag-and-drop file transfers |
| IconExtraction | 0x10 | Can extract high-resolution icons from executables |
| ShortcutDetection | 0x20 | Monitors for new/changed .lnk shortcuts |
| HighDpiSupport | 0x40 | Properly handles DPI scaling |
| MultiMonitor | 0x80 | Supports multiple display configurations |

**Core capabilities** (WindowTracking, DesktopDuplication, ClipboardSync, IconExtraction) are expected from all production guest agents.

## Message Types (Implemented)

### Host → Guest (0x00-0x7F)

| Type | Code | Description |
|------|------|-------------|
| LaunchProgram | 0x01 | Request to launch an executable with args/env |
| RequestIcon | 0x02 | Extract icon for a specific executable path |
| ClipboardData | 0x03 | Push clipboard content to guest |
| MouseInput | 0x04 | Forward mouse events (move, click, scroll) |
| KeyboardInput | 0x05 | Forward keyboard events (keydown, keyup) |
| DragDropEvent | 0x06 | Drag-and-drop lifecycle events |
| Shutdown | 0x0F | Graceful shutdown request with timeout |

### Guest → Host (0x80-0xFF)

| Type | Code | Description |
|------|------|-------------|
| WindowMetadata | 0x80 | Window bounds, title, state changes |
| FrameData | 0x81 | Frame header (pixel data follows separately) |
| CapabilityFlags | 0x82 | Initial handshake with version and capabilities |
| DpiInfo | 0x83 | Display DPI and monitor configuration |
| IconData | 0x84 | Extracted icon PNG with hash for deduplication |
| ShortcutDetected | 0x85 | New or updated Windows shortcut |
| ClipboardChanged | 0x86 | Guest clipboard content for sync to host |
| Heartbeat | 0x87 | Agent health with window count, resource usage |
| TelemetryReport | 0x88 | Performance and diagnostic telemetry |
| Error | 0xFE | Error notification with code and message |
| Ack | 0xFF | Acknowledgement of host message |

## Schema Management

- Protocol constants are defined in `shared/protocol.def` — the single source of truth
- Platform-specific code is generated:
  - Swift: `host/Sources/WinRunSpiceBridge/Protocol.generated.swift`
  - C#: `guest/WinRunAgent/Protocol.generated.cs`
- Run `make generate-protocol` after editing `protocol.def`, then commit all changed files
- CI validates generated files match source — failing if you forget to regenerate
- All message types use JSON payloads with camelCase keys for cross-platform consistency
- Changes to message schemas require:
  1. Edit `shared/protocol.def`
  2. Run `make generate-protocol`
  3. Update message DTOs in both Swift and C# if fields changed
  4. Increment minor version for additive changes (new optional fields)
  5. Increment major version for breaking changes (removed/renamed fields, type changes)
  6. Commit all changes atomically

## Security & Reliability
- Authenticate XPC callers (CLI, app shells) via entitlement or group membership checks before allowing VM control.
- All payloads need validation, replay protection, and timeout handling to prevent host/guest desyncs.
- Critical commands (program launch, shutdown) should be idempotent; retries from either side must not duplicate work.

## XPC Authentication (Implemented)

The daemon authenticates incoming XPC connections using a layered approach configured via `XPCAuthenticationConfig`:

1. **Unix Group Membership** — Verifies the effective UID belongs to an allowed group (default: `staff`). Uses POSIX `getgrouplist()` to check both primary and supplementary groups.

2. **Code Signature Validation** — Uses Security.framework to verify the connecting process has a valid code signature:
   - `SecCodeCopyGuestWithAttributes` obtains the `SecCode` for the PID
   - `SecCodeCheckValidity` confirms the signature is intact
   - `SecCodeCopySigningInformation` extracts team ID and bundle identifier

3. **Team Identifier Check** — Optionally restricts connections to binaries signed by a specific Apple Developer Team ID.

4. **Bundle Identifier Prefix** — Restricts connections to binaries whose bundle ID starts with allowed prefixes (default: `com.winrun.`).

Configuration modes:
- **Development** (`XPCAuthenticationConfig.development`): Allows unsigned clients, permissive rate limits
- **Production** (`XPCAuthenticationConfig.production`): Requires valid signatures, stricter controls

## Request Throttling (Implemented)

All XPC requests are rate-limited using a token bucket algorithm configured via `ThrottlingConfig`:

- **Per-client tracking** — Each client (identified by PID+UID) has an independent token bucket
- **Token bucket parameters**:
  - `maxRequestsPerWindow`: Base request allowance (default: 120/minute in production)
  - `burstAllowance`: Additional tokens for short bursts (default: 20)
  - `windowSeconds`: Time window for refill calculation (default: 60s)
  - `cooldownSeconds`: Penalty period after exhausting tokens (default: 5s)

- **Behavior**: Tokens refill continuously. When exhausted, requests return `XPCAuthenticationError.throttled` with a retry-after duration. The daemon prunes stale client entries hourly to prevent memory growth.

## Spice Channel Security

### Trust Boundary

The Spice channel operates within a controlled trust boundary:

- **Host to Guest**: The daemon is the sole initiator of Spice connections. Guest agents only accept connections from the hypervisor's virtual network interface.
- **Guest to Host**: The guest agent authenticates during handshake by providing its protocol version and capabilities. The host validates the protocol version before processing any subsequent messages.
- **No External Network**: Spice traffic never traverses external networks—it uses virtio/vhost-user shared memory or internal VM sockets.

### Message Validation

All messages are validated before processing:

1. **Envelope validation**: Type byte must be a known `SpiceMessageType` value; length must not exceed maximum payload size
2. **Direction validation**: Host rejects host→guest message types received from guest (and vice versa)
3. **JSON schema validation**: Payloads must deserialize cleanly to expected types; unknown fields are ignored for forward compatibility
4. **Semantic validation**: Message-specific rules (e.g., window IDs must reference tracked windows, paths must be valid)

### Replay Protection

- **Message IDs**: Host→guest messages include a unique `messageId` that the guest echoes in `Ack` responses
- **Timestamps**: Guest→host messages include Unix millisecond timestamps; stale messages beyond threshold are logged but processed
- **Sequence numbers**: Clipboard sync uses `sequenceNumber` to prevent applying stale clipboard content

### Resource Limits

- **Maximum payload size**: 16MB (configurable) to prevent memory exhaustion from malformed length fields
- **Frame data**: Sent as header + separate binary blob to avoid JSON encoding overhead for large data
- **Icon cache**: Guest caches extracted icons by path hash; host uses `iconHash` field to deduplicate transfers

### Error Handling

- **Protocol errors**: Invalid message format results in `SpiceProtocolError` logged on host; connection may be reset for persistent errors
- **Application errors**: Guest sends `Error` message with code and human-readable message; host logs and may retry operation
- **Connection loss**: Host implements exponential backoff reconnection with configurable max attempts
