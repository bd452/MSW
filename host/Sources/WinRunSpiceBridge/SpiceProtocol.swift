import Foundation
import WinRunShared

// MARK: - Protocol Version Extensions

/// Extensions to SpiceProtocolVersion (generated in Protocol.generated.swift)
extension SpiceProtocolVersion {
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

// MARK: - Guest Capabilities Extensions

/// Extensions to GuestCapabilities (generated in Protocol.generated.swift)
extension GuestCapabilities: CustomStringConvertible {
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
