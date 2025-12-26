# Bug Check Analysis

## Checked Items

- [x] `TODO.md` → Host Platform → WinRunSpiceBridge production binding → **Replace mock timer stream with libspice-glib delegate plumbing**
  - **Scope audited**: `host/Sources/WinRunSpiceBridge/SpiceWindowStream.swift`, `host/Sources/WinRunSpiceBridge/SpiceStreamTransport.swift`, `host/Sources/CSpiceBridge/CSpiceBridge.c` (current dependencies for callback delivery)
  - **Findings**
    - **Fix**: `SpiceWindowStream` never subscribed to the transport control callback, so it could not receive guest window metadata/clipboard (and would never receive frames once implemented). Added control-channel buffering + parsing and wired `setControlCallback`.
    - **Fix**: `LibSpiceStreamTransport` never registered `winrun_spice_set_clipboard_callback`, so guest→host clipboard updates were silently dropped. Wired the callback and added a Swift trampoline.
    - **Fix**: The C shim did not run a GLib main loop on macOS, so libspice signal callbacks (`channel-new`, `port-data`, clipboard signals) would not be dispatched. Added a dedicated GLib main-loop worker thread and graceful shutdown.
    - **Needs follow-up (separate TODO items)**: Guest code currently doesn’t send `FrameDataMessage` + raw frame payloads on the control channel (no calls to `CreateFrameHeader` / `SerializeFrame`), so real frame streaming can’t work end-to-end yet.

