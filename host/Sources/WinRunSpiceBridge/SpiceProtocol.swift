import Foundation
import WinRunShared

// MARK: - Protocol Version

/// Protocol version for host↔guest Spice channel communication.
/// Both host and guest must agree on compatible versions during handshake.
public enum SpiceProtocolVersion {
    /// Major version - incompatible changes increment this
    public static let major: UInt16 = 1
    /// Minor version - backwards-compatible additions increment this
    public static let minor: UInt16 = 0

    /// Combined version as a single UInt32 for comparison
    /// Format: upper 16 bits = major, lower 16 bits = minor
    public static var combined: UInt32 {
        (UInt32(major) << 16) | UInt32(minor)
    }

    /// Check if a guest protocol version is compatible with this host
    /// - Parameter guestVersion: Combined version from guest's CapabilityFlags message
    /// - Returns: True if compatible (same major, guest minor <= host minor)
    public static func isCompatible(with guestVersion: UInt32) -> Bool {
        let guestMajor = UInt16(guestVersion >> 16)
        let guestMinor = UInt16(guestVersion & 0xFFFF)

        // Must match major version
        guard guestMajor == major else { return false }

        // Guest minor must be <= host minor (host can handle older guests)
        return guestMinor <= minor
    }

    /// Parse a combined version into (major, minor) tuple
    public static func parse(_ combined: UInt32) -> (major: UInt16, minor: UInt16) {
        (UInt16(combined >> 16), UInt16(combined & 0xFFFF))
    }

    /// Format version as "major.minor" string
    public static func format(_ combined: UInt32) -> String {
        let (maj, min) = parse(combined)
        return "\(maj).\(min)"
    }

    /// Current version string
    public static var versionString: String {
        "\(major).\(minor)"
    }
}

// MARK: - Message Types

/// Message type identifiers for Spice channel serialization.
/// Must remain in sync with guest's SpiceMessageType enum.
/// Values 0x00-0x7F are reserved for host→guest messages.
/// Values 0x80-0xFF are reserved for guest→host messages.
public enum SpiceMessageType: UInt8, Codable {
    // Host → Guest (0x00-0x7F)
    case launchProgram = 0x01
    case requestIcon = 0x02
    case clipboardData = 0x03
    case mouseInput = 0x04
    case keyboardInput = 0x05
    case dragDropEvent = 0x06
    case listSessions = 0x08
    case closeSession = 0x09
    case listShortcuts = 0x0A
    case shutdown = 0x0F

    // Guest → Host (0x80-0xFF)
    case windowMetadata = 0x80
    case frameData = 0x81
    case capabilityFlags = 0x82
    case dpiInfo = 0x83
    case iconData = 0x84
    case shortcutDetected = 0x85
    case clipboardChanged = 0x86
    case heartbeat = 0x87
    case telemetryReport = 0x88
    case provisionProgress = 0x89
    case provisionError = 0x8A
    case provisionComplete = 0x8B
    case sessionList = 0x8C
    case shortcutList = 0x8D
    case error = 0xFE
    case ack = 0xFF

    /// Whether this is a host→guest message type
    public var isHostToGuest: Bool {
        rawValue < 0x80
    }

    /// Whether this is a guest→host message type
    public var isGuestToHost: Bool {
        rawValue >= 0x80
    }
}

// MARK: - Guest Capabilities

/// Capability flags reported by the guest agent during handshake.
/// Used by host to determine available features and adjust behavior.
public struct GuestCapabilities: OptionSet, Codable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let windowTracking = GuestCapabilities(rawValue: 1 << 0)
    public static let desktopDuplication = GuestCapabilities(rawValue: 1 << 1)
    public static let clipboardSync = GuestCapabilities(rawValue: 1 << 2)
    public static let dragDrop = GuestCapabilities(rawValue: 1 << 3)
    public static let iconExtraction = GuestCapabilities(rawValue: 1 << 4)
    public static let shortcutDetection = GuestCapabilities(rawValue: 1 << 5)
    public static let highDpiSupport = GuestCapabilities(rawValue: 1 << 6)
    public static let multiMonitor = GuestCapabilities(rawValue: 1 << 7)

    /// All core capabilities expected from a fully-featured guest
    public static let allCore: GuestCapabilities = [
        .windowTracking, .desktopDuplication, .clipboardSync, .iconExtraction,
    ]

    /// Description of enabled capabilities
    public var description: String {
        var parts: [String] = []
        if contains(.windowTracking) { parts.append("windowTracking") }
        if contains(.desktopDuplication) { parts.append("desktopDuplication") }
        if contains(.clipboardSync) { parts.append("clipboardSync") }
        if contains(.dragDrop) { parts.append("dragDrop") }
        if contains(.iconExtraction) { parts.append("iconExtraction") }
        if contains(.shortcutDetection) { parts.append("shortcutDetection") }
        if contains(.highDpiSupport) { parts.append("highDpiSupport") }
        if contains(.multiMonitor) { parts.append("multiMonitor") }
        return "[\(parts.joined(separator: ", "))]"
    }
}

// MARK: - Protocol Errors

/// Errors that can occur during Spice protocol operations.
public enum SpiceProtocolError: Error, CustomStringConvertible {
    case unknownMessageType
    case invalidMessageType(UInt8)
    case unexpectedMessageDirection(SpiceMessageType)
    case incompatibleVersion(guest: UInt32, host: UInt32)
    case serializationFailed(Error)
    case deserializationFailed(Error)

    public var description: String {
        switch self {
        case .unknownMessageType:
            return "Unknown host message type"
        case .invalidMessageType(let byte):
            return "Invalid message type byte: 0x\(String(byte, radix: 16, uppercase: true))"
        case .unexpectedMessageDirection(let type):
            return "Received message of unexpected direction: \(type)"
        case .incompatibleVersion(let guest, let host):
            let guestStr = SpiceProtocolVersion.format(guest)
            let hostStr = SpiceProtocolVersion.format(host)
            return "Protocol version mismatch: guest=\(guestStr), host=\(hostStr)"
        case .serializationFailed(let error):
            return "Serialization failed: \(error)"
        case .deserializationFailed(let error):
            return "Deserialization failed: \(error)"
        }
    }
}

// MARK: - Version Negotiation

/// Result of protocol version negotiation.
public struct VersionNegotiationResult: CustomStringConvertible {
    public let isCompatible: Bool
    public let hostVersion: UInt32
    public let guestVersion: UInt32
    public let guestCapabilities: GuestCapabilities
    public let guestAgentVersion: String
    public let guestOsVersion: String

    public init(from capabilityMessage: CapabilityFlagsMessage) {
        self.hostVersion = SpiceProtocolVersion.combined
        self.guestVersion = capabilityMessage.protocolVersion
        self.isCompatible = SpiceProtocolVersion.isCompatible(
            with: capabilityMessage.protocolVersion)
        self.guestCapabilities = capabilityMessage.capabilities
        self.guestAgentVersion = capabilityMessage.agentVersion
        self.guestOsVersion = capabilityMessage.osVersion
    }

    public var description: String {
        let hostStr = SpiceProtocolVersion.format(hostVersion)
        let guestStr = SpiceProtocolVersion.format(guestVersion)
        return """
            Version Negotiation:
              Host: \(hostStr)
              Guest: \(guestStr)
              Compatible: \(isCompatible)
              Agent: \(guestAgentVersion)
              OS: \(guestOsVersion)
              Capabilities: \(guestCapabilities.description)
            """
    }
}
