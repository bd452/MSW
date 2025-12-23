import Foundation
import WinRunShared

/// Errors that can occur during control channel operations.
public enum SpiceControlError: Error, CustomStringConvertible {
    case notConnected
    case timeout
    case sendFailed(Error)
    case unexpectedResponse(String)
    case protocolError(SpiceProtocolError)
    case guestError(code: String, message: String)

    public var description: String {
        switch self {
        case .notConnected:
            return "Control channel not connected"
        case .timeout:
            return "Request timed out"
        case .sendFailed(let error):
            return "Failed to send message: \(error.localizedDescription)"
        case .unexpectedResponse(let details):
            return "Unexpected response: \(details)"
        case .protocolError(let error):
            return "Protocol error: \(error.description)"
        case .guestError(let code, let message):
            return "Guest error [\(code)]: \(message)"
        }
    }
}

/// Delegate protocol for SpiceControlChannel events.
public protocol SpiceControlChannelDelegate: AnyObject {
    /// Called when the control channel connects to the guest.
    func controlChannelDidConnect(_ channel: SpiceControlChannel)

    /// Called when the control channel disconnects from the guest.
    func controlChannelDidDisconnect(_ channel: SpiceControlChannel)

    /// Called when a guest message is received that isn't a response to a pending request.
    func controlChannel(_ channel: SpiceControlChannel, didReceiveMessage message: Any, type: SpiceMessageType)
}

/// Extension with default implementations
public extension SpiceControlChannelDelegate {
    func controlChannelDidConnect(_ channel: SpiceControlChannel) {}
    func controlChannelDidDisconnect(_ channel: SpiceControlChannel) {}
    func controlChannel(_ channel: SpiceControlChannel, didReceiveMessage message: Any, type: SpiceMessageType) {}
}

/// A control channel for sending commands to the guest agent and receiving responses.
///
/// This channel is separate from the per-window `SpiceWindowStream` and is used for
/// control messages like session listing, shutdown requests, etc.
public actor SpiceControlChannel {
    private let logger: Logger
    private let configuration: SpiceStreamConfiguration
    private var messageIdCounter: UInt32 = 0
    private var pendingRequests: [UInt32: CheckedContinuation<Any, Error>] = [:]
    private var isConnected: Bool = false

    // Transport for actual Spice communication
    private var transport: SpiceStreamTransport?
    private var transportSubscription: SpiceStreamSubscription?

    // Delegate (needs to be nonisolated for setting from non-actor context)
    private weak var _delegate: SpiceControlChannelDelegate?

    public nonisolated var delegate: SpiceControlChannelDelegate? {
        get { nil } // Simplified - use proper actor isolation in real implementation
        set { Task { await setDelegate(newValue) } }
    }

    private func setDelegate(_ delegate: SpiceControlChannelDelegate?) {
        _delegate = delegate
    }

    public init(
        configuration: SpiceStreamConfiguration = SpiceStreamConfiguration.environmentDefault(),
        logger: Logger = StandardLogger(subsystem: "SpiceControlChannel")
    ) {
        self.configuration = configuration
        self.logger = logger
    }

    /// Initialize with an existing transport (for testing or shared connections)
    /// Note: This is internal because SpiceStreamTransport is an internal protocol
    init(
        transport: SpiceStreamTransport,
        logger: Logger = StandardLogger(subsystem: "SpiceControlChannel")
    ) {
        self.configuration = SpiceStreamConfiguration.environmentDefault()
        self.logger = logger
        self.transport = transport
    }

    /// Connect to the guest agent.
    public func connect() async throws {
        logger.info("Connecting to guest control channel")

        // Create transport if not provided
        if transport == nil {
            #if os(macOS)
            transport = LibSpiceStreamTransport(logger: logger)
            #else
            transport = MockSpiceStreamTransport(logger: logger)
            #endif
        }

        // Open a stream for control channel (windowID 0 indicates control channel)
        let callbacks = SpiceStreamCallbacks(
            onFrame: { _ in },  // Control channel doesn't receive frames
            onMetadata: { _ in },
            onClosed: { [weak self] reason in
                Task { [weak self] in
                    await self?.handleTransportClosed(reason)
                }
            },
            onClipboard: { _ in }
        )

        do {
            transportSubscription = try transport?.openStream(
                configuration: configuration,
                windowID: 0,  // Control channel uses windowID 0
                callbacks: callbacks
            )

            // Set up callback for receiving control messages
            transport?.setControlCallback { [weak self] data in
                Task { [weak self] in
                    try? await self?.handleReceivedData(data)
                }
            }

            isConnected = true
            _delegate?.controlChannelDidConnect(self)
            logger.info("Control channel connected")
        } catch {
            logger.error("Failed to connect control channel: \(error)")
            throw SpiceControlError.sendFailed(error)
        }
    }

    /// Disconnect from the guest agent.
    public func disconnect() {
        logger.info("Disconnecting from guest control channel")

        if let subscription = transportSubscription {
            transport?.closeStream(subscription)
            transportSubscription = nil
        }

        isConnected = false

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: SpiceControlError.notConnected)
        }
        pendingRequests.removeAll()
        _delegate?.controlChannelDidDisconnect(self)
    }

    private func handleTransportClosed(_ reason: SpiceStreamCloseReason) {
        logger.warn("Control channel transport closed: \(reason.message)")
        isConnected = false

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: SpiceControlError.notConnected)
        }
        pendingRequests.removeAll()
        _delegate?.controlChannelDidDisconnect(self)
    }

    /// Whether the control channel is currently connected.
    public var connected: Bool {
        isConnected
    }

    /// Request a list of active sessions from the guest.
    /// - Parameter timeout: Maximum time to wait for response
    /// - Returns: List of guest sessions
    public func listSessions(timeout: Duration = .seconds(5)) async throws -> GuestSessionList {
        let messageId = nextMessageId()
        let request = ListSessionsSpiceMessage(messageId: messageId)

        logger.debug("Sending ListSessions request (messageId: \(messageId))")

        let response = try await sendAndWait(request, messageId: messageId, timeout: timeout)

        guard let sessionList = response as? SessionListMessage else {
            throw SpiceControlError.unexpectedResponse("Expected SessionListMessage, got \(type(of: response))")
        }

        return sessionList.toGuestSessionList()
    }

    /// Request to close a session on the guest.
    /// - Parameters:
    ///   - sessionId: ID of the session to close
    ///   - timeout: Maximum time to wait for acknowledgement
    public func closeSession(_ sessionId: String, timeout: Duration = .seconds(5)) async throws {
        let messageId = nextMessageId()
        let request = CloseSessionSpiceMessage(messageId: messageId, sessionId: sessionId)

        logger.debug("Sending CloseSession request for \(sessionId) (messageId: \(messageId))")

        let response = try await sendAndWait(request, messageId: messageId, timeout: timeout)

        if let ack = response as? AckMessage {
            if !ack.success {
                throw SpiceControlError.guestError(
                    code: "CLOSE_SESSION_FAILED",
                    message: ack.errorMessage ?? "Unknown error"
                )
            }
        }
    }

    // MARK: - Internal Message Handling

    /// Called when data is received from the Spice channel.
    /// This should be called by the transport layer when messages arrive.
    public func handleReceivedData(_ data: Data) throws {
        guard let (type, message) = try SpiceMessageSerializer.deserialize(data) else {
            logger.warn("Incomplete message received")
            return
        }

        // Check if this is a response to a pending request
        let messageId: UInt32? = switch message {
        case let msg as SessionListMessage: msg.messageId
        case let msg as AckMessage: msg.messageId
        case let msg as GuestErrorMessage: msg.relatedMessageId
        default: nil
        }

        if let messageId, let continuation = pendingRequests.removeValue(forKey: messageId) {
            // This is a response to a pending request
            if let errorMsg = message as? GuestErrorMessage {
                continuation.resume(throwing: SpiceControlError.guestError(
                    code: errorMsg.code,
                    message: errorMsg.message
                ))
            } else {
                continuation.resume(returning: message)
            }
        } else {
            // Unsolicited message - notify delegate
            _delegate?.controlChannel(self, didReceiveMessage: message, type: type)
        }
    }

    // MARK: - Private Helpers

    private func nextMessageId() -> UInt32 {
        messageIdCounter += 1
        return messageIdCounter
    }

    private func sendAndWait(_ message: some HostMessage, messageId: UInt32, timeout: Duration) async throws -> Any {
        guard isConnected else {
            throw SpiceControlError.notConnected
        }

        guard let transport else {
            throw SpiceControlError.notConnected
        }

        // Serialize the message
        let data: Data
        do {
            data = try SpiceMessageSerializer.serialize(message)
        } catch {
            throw SpiceControlError.sendFailed(error)
        }

        // Send via transport
        let sent = transport.sendControlMessage(data)
        if !sent {
            throw SpiceControlError.sendFailed(
                NSError(domain: "SpiceControlChannel", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Transport failed to send message",
                ])
            )
        }

        logger.debug("Sent control message (\(data.count) bytes)")

        // Send and wait for response with timeout
        return try await withThrowingTaskGroup(of: Any.self) { group in
            // Add the request task
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                    Task {
                        await self.registerPendingRequest(messageId: messageId, continuation: continuation)
                    }
                }
            }

            // Add a timeout task
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SpiceControlError.timeout
            }

            // Wait for the first task to complete
            do {
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }
                throw SpiceControlError.timeout
            } catch {
                // Clean up pending request on timeout
                await self.removePendingRequest(messageId: messageId)
                throw error
            }
        }
    }

    private func registerPendingRequest(messageId: UInt32, continuation: CheckedContinuation<Any, Error>) {
        pendingRequests[messageId] = continuation
    }

    private func removePendingRequest(messageId: UInt32) {
        _ = pendingRequests.removeValue(forKey: messageId)
    }

    /// Simulate receiving a response (for testing purposes).
    /// In production, this would be called by the transport layer.
    public func simulateResponse(_ data: Data) throws {
        try handleReceivedData(data)
    }

    /// Simulate a connected state (for testing purposes).
    /// This also sets up a mock transport that accepts but doesn't actually send messages.
    public func simulateConnected() {
        isConnected = true
        // Create mock transport for testing if not already set
        if transport == nil {
            #if os(macOS)
            transport = LibSpiceStreamTransport(logger: logger)
            #else
            transport = MockSpiceStreamTransport(logger: logger)
            #endif
        }
    }
}
