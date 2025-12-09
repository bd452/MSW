import Foundation

// MARK: - Spice Stream Metrics

public struct SpiceStreamMetrics: Codable, Hashable {
    public var framesReceived: Int
    public var metadataUpdates: Int
    public var reconnectAttempts: Int
    public var lastErrorDescription: String?

    public init(
        framesReceived: Int = 0,
        metadataUpdates: Int = 0,
        reconnectAttempts: Int = 0,
        lastErrorDescription: String? = nil
    ) {
        self.framesReceived = framesReceived
        self.metadataUpdates = metadataUpdates
        self.reconnectAttempts = reconnectAttempts
        self.lastErrorDescription = lastErrorDescription
    }
}

