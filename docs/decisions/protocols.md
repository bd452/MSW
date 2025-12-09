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
