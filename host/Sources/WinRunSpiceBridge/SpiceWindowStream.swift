import Foundation
import CoreGraphics
import WinRunShared

/// Manages a Spice stream connection to a Windows guest window.
///
/// `SpiceWindowStream` handles:
/// - Connection lifecycle (connect, disconnect, reconnect)
/// - Frame and metadata delivery to delegate
/// - Input forwarding (mouse, keyboard)
/// - Clipboard synchronization
/// - Drag and drop events
public final class SpiceWindowStream {
    public weak var delegate: SpiceWindowStreamDelegate?

    private let configuration: SpiceStreamConfiguration
    private let delegateQueue: DispatchQueue
    private let transport: SpiceStreamTransport
    private let logger: Logger
    private let stateQueue = DispatchQueue(label: "com.winrun.spice.window-stream.state")
    private var state = StreamState()
    private var reconnectPolicy: ReconnectPolicy
    private var reconnectWorkItem: DispatchWorkItem?
    private var metrics = SpiceStreamMetrics()
    private var controlBuffer = Data()
    private var pendingFrame: PendingSpiceFrame?

    public convenience init(
        configuration: SpiceStreamConfiguration = SpiceStreamConfiguration.environmentDefault(),
        delegateQueue: DispatchQueue = .main,
        logger: Logger = StandardLogger(subsystem: "SpiceWindowStream"),
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy()
    ) {
        self.init(
            configuration: configuration,
            delegateQueue: delegateQueue,
            logger: logger,
            transport: nil,
            reconnectPolicy: reconnectPolicy
        )
    }

    init(
        configuration: SpiceStreamConfiguration = SpiceStreamConfiguration.environmentDefault(),
        delegateQueue: DispatchQueue = .main,
        logger: Logger = StandardLogger(subsystem: "SpiceWindowStream"),
        transport: SpiceStreamTransport?,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy()
    ) {
        self.configuration = configuration
        self.delegateQueue = delegateQueue
        self.logger = logger
        self.reconnectPolicy = reconnectPolicy
        #if os(macOS)
        self.transport = transport ?? LibSpiceStreamTransport(logger: logger)
        #else
        self.transport = transport ?? MockSpiceStreamTransport(logger: logger)
        #endif
    }

    // MARK: - Connection Lifecycle

    public func connect(toWindowID windowID: UInt64) {
        stateQueue.async {
            guard self.state.lifecycle == .disconnected else {
                self.logger.debug("Ignoring duplicate connect for window \(windowID)")
                return
            }

            self.logger.info("Connecting to Spice stream for window \(windowID) via \(self.transportDescription())")
            self.state.windowID = windowID
            self.state.isUserInitiatedClose = false
            self.state.lifecycle = .connecting
            self.metrics.lastErrorDescription = nil
            self.notifyStateChange(.connecting)
            self.openStream(for: windowID)
        }
    }

    /// Returns the current public connection state.
    public var connectionState: SpiceConnectionState {
        stateQueue.sync {
            switch state.lifecycle {
            case .disconnected:
                if let error = metrics.lastErrorDescription, !error.isEmpty {
                    return .failed(reason: error)
                }
                return .disconnected
            case .connecting:
                return .connecting
            case .connected:
                return .connected
            case .reconnecting:
                return .reconnecting(
                    attempt: metrics.reconnectAttempts,
                    maxAttempts: reconnectPolicy.maxAttempts
                )
            }
        }
    }

    public func disconnect() {
        stateQueue.async {
            self.logger.info("Disconnect requested for window stream")
            self.state.isUserInitiatedClose = true
            self.cancelReconnect()
            guard let subscription = self.state.subscription else {
                self.finishDisconnect()
                return
            }

            self.transport.closeStream(subscription)
            self.state.subscription = nil
            self.finishDisconnect()
        }
    }

    /// Manually trigger a reconnection attempt.
    /// Useful for retry buttons after permanent failure.
    public func reconnect() {
        stateQueue.async {
            guard let windowID = self.state.windowID else {
                self.logger.warn("Cannot reconnect - no previous window ID")
                return
            }

            // Reset error state and attempt counter for manual retry
            self.metrics.lastErrorDescription = nil
            self.metrics.reconnectAttempts = 0
            self.state.isUserInitiatedClose = false

            // If currently connected/connecting, disconnect first
            if self.state.lifecycle != .disconnected {
                if let subscription = self.state.subscription {
                    self.transport.closeStream(subscription)
                    self.state.subscription = nil
                }
                self.cancelReconnect()
            }

            self.logger.info("Manual reconnect requested for window \(windowID)")
            self.state.lifecycle = .connecting
            self.notifyStateChange(.connecting)
            self.openStream(for: windowID)
        }
    }

    /// Pause the stream when window is not visible (minimized, hidden).
    /// This helps conserve resources while the window is out of sight.
    public func pause() {
        stateQueue.async {
            guard self.state.lifecycle == .connected else { return }
            self.state.isPaused = true
            self.logger.debug("Stream paused (window not visible)")
            // Note: We don't disconnect - just flag that we're paused
            // Transport can optionally reduce frame rate or buffer frames
        }
    }

    /// Resume the stream when window becomes visible again.
    public func resume() {
        stateQueue.async {
            guard self.state.isPaused else { return }
            self.state.isPaused = false
            self.logger.debug("Stream resumed (window visible)")

            // If we disconnected while paused, reconnect
            if self.state.lifecycle == .disconnected, let windowID = self.state.windowID {
                self.state.isUserInitiatedClose = false
                self.state.lifecycle = .connecting
                self.notifyStateChange(.connecting)
                self.openStream(for: windowID)
            }
        }
    }

    /// Whether the stream is currently paused due to window visibility.
    public var isPaused: Bool {
        stateQueue.sync { state.isPaused }
    }

    public func metricsSnapshot() -> SpiceStreamMetrics {
        stateQueue.sync { metrics }
    }

    // MARK: - Input Forwarding

    /// Send a mouse event to the Windows guest
    public func sendMouseEvent(_ event: MouseInputEvent) {
        stateQueue.async {
            guard self.state.lifecycle == .connected else {
                self.logger.debug("Dropping mouse event - stream not connected")
                return
            }
            self.transport.sendMouseEvent(event)
        }
    }

    /// Send a keyboard event to the Windows guest
    public func sendKeyboardEvent(_ event: KeyboardInputEvent) {
        stateQueue.async {
            guard self.state.lifecycle == .connected else {
                self.logger.debug("Dropping keyboard event - stream not connected")
                return
            }
            self.transport.sendKeyboardEvent(event)
        }
    }

    // MARK: - Clipboard

    /// Send clipboard data to the Windows guest
    public func sendClipboard(_ clipboard: ClipboardData) {
        stateQueue.async {
            guard self.state.lifecycle == .connected else {
                self.logger.debug("Dropping clipboard data - stream not connected")
                return
            }
            self.transport.sendClipboard(clipboard)
        }
    }

    /// Request clipboard content from the Windows guest
    public func requestClipboard(format: ClipboardFormat = .plainText) {
        stateQueue.async {
            guard self.state.lifecycle == .connected else {
                self.logger.debug("Cannot request clipboard - stream not connected")
                return
            }
            self.transport.requestClipboard(format: format)
        }
    }

    // MARK: - Drag and Drop

    /// Send a drag and drop event to the Windows guest
    public func sendDragDropEvent(_ event: DragDropEvent) {
        stateQueue.async {
            guard self.state.lifecycle == .connected else {
                self.logger.debug("Dropping drag event - stream not connected")
                return
            }
            self.transport.sendDragDropEvent(event)
        }
    }

    // MARK: - Private Implementation

    private func openStream(for windowID: UInt64) {
        let callbacks = SpiceStreamCallbacks(
            onFrame: { [weak self] data in
                self?.handleFrame(data)
            },
            onMetadata: { [weak self] metadata in
                self?.handleMetadata(metadata)
            },
            onClosed: { [weak self] reason in
                self?.handleClose(reason: reason)
            },
            onClipboard: { [weak self] clipboard in
                self?.handleClipboard(clipboard)
            }
        )

        do {
            let subscription = try transport.openStream(
                configuration: configuration,
                windowID: windowID,
                callbacks: callbacks
            )
            state.subscription = subscription
            state.lifecycle = .connected
            reconnectWorkItem = nil
            metrics.reconnectAttempts = 0
            controlBuffer.removeAll(keepingCapacity: true)
            pendingFrame = nil

            // Per-window streams receive metadata/frames over the control port.
            // The transport callback can deliver partial chunks, so we buffer and parse.
            transport.setControlCallback { [weak self] chunk in
                self?.handleControlChunk(chunk)
            }

            logger.info("Spice stream connected for window \(windowID)")
            notifyStateChange(.connected)
        } catch let error as SpiceStreamError {
            switch error {
            case .sharedMemoryUnavailable(let description):
                metrics.lastErrorDescription = description
                logger.error("Shared-memory Spice stream unavailable: \(description)")
                notifyStateChange(.failed(reason: description))
                finishDisconnect()
            case .connectionFailed(let description):
                metrics.lastErrorDescription = description
                logger.error("Failed to connect Spice stream: \(description)")
                scheduleReconnect(reason: SpiceStreamCloseReason(code: .transportError, message: description))
            }
        } catch {
            metrics.lastErrorDescription = error.localizedDescription
            logger.error("Unexpected Spice bridge error: \(error.localizedDescription)")
            scheduleReconnect(reason: SpiceStreamCloseReason(code: .transportError, message: error.localizedDescription))
        }
    }

    private func handleFrame(_ frame: Data) {
        stateQueue.async {
            self.metrics.framesReceived += 1
            guard let delegate = self.delegate else { return }
            self.delegateQueue.async { [weak self] in
                guard let self else { return }
                delegate.windowStream(self, didUpdateFrame: frame)
            }
        }
    }

    private func handleMetadata(_ metadata: WindowMetadata) {
        stateQueue.async {
            self.metrics.metadataUpdates += 1
            guard let delegate = self.delegate else { return }
            self.delegateQueue.async { [weak self] in
                guard let self else { return }
                delegate.windowStream(self, didUpdateMetadata: metadata)
            }
        }
    }

    private func handleClipboard(_ clipboard: ClipboardData) {
        stateQueue.async {
            guard let delegate = self.delegate else { return }
            self.delegateQueue.async { [weak self] in
                guard let self else { return }
                delegate.windowStream(self, didReceiveClipboard: clipboard)
            }
        }
    }

    private func handleClose(reason: SpiceStreamCloseReason) {
        stateQueue.async {
            self.logger.warn("Spice stream closed: \(reason)")
            let wasUserInitiated = self.state.isUserInitiatedClose
            self.state.subscription = nil
            self.metrics.lastErrorDescription = reason.message

            switch reason.code {
            case .remoteClosed where !wasUserInitiated:
                self.finishDisconnect()
            case .transportError where !wasUserInitiated:
                self.scheduleReconnect(reason: reason)
            case .authenticationFailed:
                self.finishDisconnect()
            case .sharedMemoryUnavailable:
                self.finishDisconnect()
            default:
                self.finishDisconnect()
            }
        }
    }

    private func scheduleReconnect(reason: SpiceStreamCloseReason) {
        guard let windowID = state.windowID else { return }
        metrics.reconnectAttempts += 1
        let attempt = metrics.reconnectAttempts
        if let maxAttempts = reconnectPolicy.maxAttempts, attempt > maxAttempts {
            logger.error("Spice reconnect limit (\(maxAttempts)) reached due to \(reason.code); giving up")
            metrics.lastErrorDescription = reason.message
            notifyStateChange(.failed(reason: reason.message))
            finishDisconnect()
            return
        }
        let delay = reconnectPolicy.delay(for: attempt)
        state.lifecycle = .reconnecting
        notifyStateChange(.reconnecting(attempt: attempt, maxAttempts: reconnectPolicy.maxAttempts))

        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                guard !self.state.isUserInitiatedClose else { return }
                self.logger.info("Attempting Spice reconnect #\(attempt) for window \(windowID)")
                self.openStream(for: windowID)
            }
        }

        reconnectWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func finishDisconnect() {
        let hadError = metrics.lastErrorDescription != nil && !metrics.lastErrorDescription!.isEmpty
        state.lifecycle = .disconnected
        cancelReconnect()

        // Notify state change before the close callback
        if hadError {
            notifyStateChange(.failed(reason: metrics.lastErrorDescription!))
        } else {
            notifyStateChange(.disconnected)
        }

        delegateQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.windowStreamDidClose(self)
        }
    }

    private func transportDescription() -> String {
        configuration.transport.summaryDescription
    }

    private func notifyStateChange(_ newState: SpiceConnectionState) {
        guard let delegate else { return }
        delegateQueue.async { [weak self] in
            guard let self else { return }
            delegate.windowStream(self, didChangeState: newState)
        }
    }
}

// MARK: - Control Channel Parsing

private struct PendingSpiceFrame {
    let windowID: UInt64
    var remainingBytes: Int
    let shouldDeliver: Bool
    var collected: Data

    init(windowID: UInt64, remainingBytes: Int, shouldDeliver: Bool) {
        self.windowID = windowID
        self.remainingBytes = remainingBytes
        self.shouldDeliver = shouldDeliver
        self.collected = Data(capacity: max(0, remainingBytes))
    }
}

extension SpiceWindowStream {
    /// Handle a raw chunk of bytes received from the Spice control port.
    /// The stream contains a mix of:
    /// - Envelope messages: `[Type:1][Length:4][Payload:N]`
    /// - Optional raw frame payloads following a `FrameDataMessage` header.
    func handleControlChunk(_ chunk: Data) {
        stateQueue.async {
            guard !chunk.isEmpty else { return }

            // If we're in the middle of consuming a raw frame payload, do that first.
            if var pending = self.pendingFrame {
                let take = min(pending.remainingBytes, chunk.count)
                if take > 0, pending.shouldDeliver {
                    pending.collected.append(chunk.prefix(take))
                }
                pending.remainingBytes -= take

                if pending.remainingBytes <= 0 {
                    if pending.shouldDeliver {
                        self.handleFrame(pending.collected)
                    }
                    self.pendingFrame = nil
                } else {
                    self.pendingFrame = pending
                }

                // Continue processing any leftover bytes after the frame payload.
                if take < chunk.count {
                    self.controlBuffer.append(chunk.suffix(chunk.count - take))
                }
            } else {
                self.controlBuffer.append(chunk)
            }

            self.drainControlBuffer()
        }
    }

    private func drainControlBuffer() {
        // Parse zero or more envelope messages out of the stream buffer.
        while true {
            // If a frame payload is pending, we must stop parsing envelopes until it completes.
            if pendingFrame != nil {
                return
            }

            do {
                let result = try SpiceMessageSerializer.tryReadMessage(from: controlBuffer)
                guard result.bytesConsumed > 0 else { return }

                defer {
                    controlBuffer.removeFirst(result.bytesConsumed)
                }

                guard let type = result.type, let message = result.message else {
                    // Unknown message type: skip consumed bytes and continue.
                    continue
                }

                // Dispatch only the messages relevant to window streams. We still need to
                // observe frame headers for *all* windows so we can correctly consume the
                // following raw frame payload from the byte stream.
                switch type {
                case .windowMetadata:
                    guard let metadata = message as? WindowMetadataMessage else { continue }
                    handleWindowMetadataMessage(metadata)

                case .frameData:
                    guard let frameHeader = message as? FrameDataMessage else { continue }
                    let expected = Int(frameHeader.dataLength)
                    let shouldDeliver = frameHeader.windowId == state.windowID
                    pendingFrame = PendingSpiceFrame(
                        windowID: frameHeader.windowId,
                        remainingBytes: expected,
                        shouldDeliver: shouldDeliver
                    )

                case .clipboardChanged:
                    guard let clipboard = message as? GuestClipboardMessage else { continue }
                    let data = ClipboardData(
                        format: clipboard.format,
                        data: clipboard.data,
                        sequenceNumber: clipboard.sequenceNumber
                    )
                    handleClipboard(data)

                default:
                    // Ignore other unsolicited messages (session list, provisioning, telemetry, etc.)
                    continue
                }
            } catch {
                // If parsing fails, drop the buffer (prevents infinite loops) and surface the error.
                metrics.lastErrorDescription = "Spice control parse error: \(error.localizedDescription)"
                logger.error(metrics.lastErrorDescription ?? "Spice control parse error")
                controlBuffer.removeAll(keepingCapacity: true)
                return
            }
        }
    }

    private func handleWindowMetadataMessage(_ message: WindowMetadataMessage) {
        // If this stream is bound to a specific windowID, filter by it.
        if let boundWindowID = state.windowID, boundWindowID != 0, message.windowId != boundWindowID {
            return
        }

        let frame = CGRect(
            x: Double(message.bounds.x),
            y: Double(message.bounds.y),
            width: Double(message.bounds.width),
            height: Double(message.bounds.height)
        )

        let metadata = WindowMetadata(
            windowID: message.windowId,
            title: message.title,
            frame: frame,
            isResizable: message.isResizable,
            scaleFactor: CGFloat(message.scaleFactor)
        )
        handleMetadata(metadata)
    }
}
