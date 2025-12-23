import Foundation

// MARK: - Clipboard Types
// Note: ClipboardFormat enum is defined in Protocol.generated.swift

/// Direction of clipboard synchronization
public enum ClipboardDirection: Int32, Codable, Hashable, Sendable {
    case hostToGuest = 0
    case guestToHost = 1
}

/// Clipboard data to be synchronized between host and guest
public struct ClipboardData: Codable, Hashable, Sendable {
    /// The format of the clipboard content
    public let format: ClipboardFormat

    /// The actual data (encoded appropriately for the format)
    public let data: Data

    /// Sequence number for ordering/deduplication
    public let sequenceNumber: UInt64

    public init(format: ClipboardFormat, data: Data, sequenceNumber: UInt64 = 0) {
        self.format = format
        self.data = data
        self.sequenceNumber = sequenceNumber
    }

    /// Create clipboard data from a string
    public static func text(_ string: String, sequenceNumber: UInt64 = 0) -> ClipboardData? {
        guard let data = string.data(using: .utf8) else { return nil }
        return ClipboardData(format: .plainText, data: data, sequenceNumber: sequenceNumber)
    }

    /// Extract text content if format is plainText
    public var textContent: String? {
        guard format == .plainText else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A clipboard synchronization event
public struct ClipboardEvent: Codable, Hashable, Sendable {
    /// Direction of the sync
    public let direction: ClipboardDirection

    /// Available formats (best format first)
    public let availableFormats: [ClipboardFormat]

    /// The clipboard data for the preferred format
    public let content: ClipboardData?

    public init(
        direction: ClipboardDirection,
        availableFormats: [ClipboardFormat],
        content: ClipboardData? = nil
    ) {
        self.direction = direction
        self.availableFormats = availableFormats
        self.content = content
    }
}
