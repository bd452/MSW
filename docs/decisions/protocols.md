# Host ↔ Guest Protocol Decisions

## Transport Layer
- Control flows originate from macOS targets via XPC and terminate in the daemon, which relays commands to the guest over custom Spice channels.
- Guest components expose symmetrical handlers that parse the shared payload schema and respond with acknowledgements plus telemetry.

## Schema Management
- Swift models in `WinRunXPC` and C# DTOs in the guest must remain version compatible; changes require explicit version fields and negotiation logic before rollout.
- Window metadata payloads must include bounds, DPI scaling, icon hashes, capability flags (clipboard, menus, drag/drop), and session identifiers.

## Security & Reliability
- Authenticate XPC callers (CLI, app shells) via entitlement or group membership checks before allowing VM control.
- All payloads need validation, replay protection, and timeout handling to prevent host/guest desyncs.
- Critical commands (program launch, shutdown) should be idempotent; retries from either side must not duplicate work.
