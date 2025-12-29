import Foundation
import WinRunShared

// MARK: - Parse Result

/// Result of attempting to read a message from a buffer.
public struct SpiceMessageParseResult {
    /// Number of bytes consumed from the buffer (0 if incomplete)
    public let bytesConsumed: Int
    /// Message type if successfully parsed
    public let type: SpiceMessageType?
    /// Decoded message payload if successfully parsed
    public let message: Any?

    /// Whether a complete message was parsed
    public var isComplete: Bool {
        bytesConsumed > 0 && type != nil
    }

    public static let incomplete = SpiceMessageParseResult(bytesConsumed: 0, type: nil, message: nil)
}

// MARK: - Message Serializer

/// Serializes and deserializes Spice channel messages using a binary envelope format.
/// Message format: [Type:1][Length:4][Payload:N]
/// Payload is JSON-encoded for flexibility and debuggability.
///
/// JSON uses camelCase keys to match the guest's serialization format.
public enum SpiceMessageSerializer {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Use default key encoding (camelCase) to match guest's JsonNamingPolicy.CamelCase
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Use default key decoding (camelCase) to match guest's JsonNamingPolicy.CamelCase
        return decoder
    }()

    // MARK: - Serialization (Host → Guest)

    /// Serialize a host message to bytes for transmission over Spice channel.
    public static func serialize(_ message: some HostMessage) throws -> Data {
        let type: SpiceMessageType
        switch message {
        case is LaunchProgramSpiceMessage:
            type = .launchProgram
        case is RequestIconSpiceMessage:
            type = .requestIcon
        case is HostClipboardSpiceMessage:
            type = .clipboardData
        case is MouseInputSpiceMessage:
            type = .mouseInput
        case is KeyboardInputSpiceMessage:
            type = .keyboardInput
        case is DragDropSpiceMessage:
            type = .dragDropEvent
        case is ConfigureStreamingSpiceMessage:
            type = .configureStreaming
        case is ListSessionsSpiceMessage:
            type = .listSessions
        case is CloseSessionSpiceMessage:
            type = .closeSession
        case is ListShortcutsSpiceMessage:
            type = .listShortcuts
        case is ShutdownSpiceMessage:
            type = .shutdown
        default:
            throw SpiceProtocolError.unknownMessageType
        }

        let payload = try encoder.encode(message)
        return createEnvelope(type: type, payload: payload)
    }

    // MARK: - Deserialization (Guest → Host)

    /// Deserialize a guest message from bytes received over Spice channel.
    /// - Returns: Tuple of (message type, decoded message) or nil if incomplete/invalid
    public static func deserialize(_ data: Data) throws -> (SpiceMessageType, Any)? {
        guard data.count >= 5 else {
            return nil
        }

        let type = SpiceMessageType(rawValue: data[0])
        guard let messageType = type else {
            throw SpiceProtocolError.invalidMessageType(data[0])
        }

        let length = readUInt32LittleEndian(from: data, at: 1)

        let totalLength = 5 + Int(length)
        guard data.count >= totalLength else {
            return nil
        }

        let payload = data.subdata(in: 5..<totalLength)

        let message: Any = try decodePayload(type: messageType, payload: payload)
        return (messageType, message)
    }

    /// Try to read a complete message from a stream buffer.
    /// - Returns: Parse result with bytes consumed, type, and message
    public static func tryReadMessage(from buffer: Data) throws -> SpiceMessageParseResult {
        guard buffer.count >= 5 else {
            return .incomplete
        }

        let length = readUInt32LittleEndian(from: buffer, at: 1)

        let totalLength = 5 + Int(length)
        guard buffer.count >= totalLength else {
            return .incomplete
        }

        let messageData = buffer.prefix(totalLength)
        if let (type, message) = try deserialize(Data(messageData)) {
            return SpiceMessageParseResult(bytesConsumed: totalLength, type: type, message: message)
        }

        return SpiceMessageParseResult(bytesConsumed: totalLength, type: nil, message: nil)
    }

    // MARK: - Private Helpers

    /// Read a UInt32 from data at the specified offset in little-endian byte order.
    /// This avoids alignment issues that can occur with direct memory loads.
    private static func readUInt32LittleEndian(from data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }

    private static func createEnvelope(type: SpiceMessageType, payload: Data) -> Data {
        var envelope = Data(capacity: 5 + payload.count)
        envelope.append(type.rawValue)

        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }

        envelope.append(payload)
        return envelope
    }

    private static func decodePayload(type: SpiceMessageType, payload: Data) throws -> Any {
        // Handle host→guest messages (should not be received on host)
        if type.isHostToGuest {
            throw SpiceProtocolError.unexpectedMessageDirection(type)
        }

        // Decode guest→host messages
        return try decodeGuestMessage(type: type, payload: payload)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func decodeGuestMessage(type: SpiceMessageType, payload: Data) throws -> Any {
        switch type {
        case .windowMetadata:
            return try decoder.decode(WindowMetadataMessage.self, from: payload)
        case .frameData:
            return try decoder.decode(FrameDataMessage.self, from: payload)
        case .capabilityFlags:
            return try decoder.decode(CapabilityFlagsMessage.self, from: payload)
        case .dpiInfo:
            return try decoder.decode(DpiInfoMessage.self, from: payload)
        case .iconData:
            return try decoder.decode(IconDataMessage.self, from: payload)
        case .shortcutDetected:
            return try decoder.decode(ShortcutDetectedMessage.self, from: payload)
        case .clipboardChanged:
            return try decoder.decode(GuestClipboardMessage.self, from: payload)
        case .heartbeat:
            return try decoder.decode(HeartbeatMessage.self, from: payload)
        case .telemetryReport:
            return try JSONSerialization.jsonObject(with: payload)
        case .provisionProgress:
            return try decoder.decode(ProvisionProgressMessage.self, from: payload)
        case .provisionError:
            return try decoder.decode(ProvisionErrorMessage.self, from: payload)
        case .provisionComplete:
            return try decoder.decode(ProvisionCompleteMessage.self, from: payload)
        case .sessionList:
            return try decoder.decode(SessionListMessage.self, from: payload)
        case .shortcutList:
            return try decoder.decode(ShortcutListMessage.self, from: payload)
        case .frameReady:
            return try decoder.decode(FrameReadyMessage.self, from: payload)
        case .windowBufferAllocated:
            return try decoder.decode(WindowBufferAllocatedMessage.self, from: payload)
        case .error:
            return try decoder.decode(GuestErrorMessage.self, from: payload)
        case .ack:
            return try decoder.decode(AckMessage.self, from: payload)
        default:
            throw SpiceProtocolError.unexpectedMessageDirection(type)
        }
    }
}
