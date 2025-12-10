import Foundation
import CoreGraphics
import WinRunShared

// MARK: - Connection State

/// Public connection state for Spice streams, exposed to UI layer for status display.
public enum SpiceConnectionState: Equatable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, maxAttempts: Int?)
    case failed(reason: String)

    public var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .reconnecting(let attempt, let maxAttempts):
            if let max = maxAttempts {
                return "Reconnecting (\(attempt)/\(max))..."
            }
            return "Reconnecting (attempt \(attempt))..."
        case .failed(let reason):
            return "Connection failed: \(reason)"
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isTransitioning: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }
}

// MARK: - Delegate Protocol

/// Delegate protocol for receiving Spice window stream events.
public protocol SpiceWindowStreamDelegate: AnyObject {
    /// Called when frame data is received from the guest.
    func windowStream(_ stream: SpiceWindowStream, didUpdateFrame frame: Data)

    /// Called when window metadata is updated.
    func windowStream(_ stream: SpiceWindowStream, didUpdateMetadata metadata: WindowMetadata)

    /// Called when the stream connection state changes.
    func windowStream(_ stream: SpiceWindowStream, didChangeState state: SpiceConnectionState)

    /// Called when the stream is permanently closed.
    func windowStreamDidClose(_ stream: SpiceWindowStream)

    /// Called when clipboard data is received from the guest.
    func windowStream(_ stream: SpiceWindowStream, didReceiveClipboard clipboard: ClipboardData)
}

public extension SpiceWindowStreamDelegate {
    // Default empty implementations for optional delegate methods
    func windowStream(_ stream: SpiceWindowStream, didChangeState state: SpiceConnectionState) {}
    func windowStream(_ stream: SpiceWindowStream, didReceiveClipboard clipboard: ClipboardData) {}
}

// MARK: - Window Metadata

/// Metadata describing a window being streamed from the Windows guest.
public struct WindowMetadata: Codable, Hashable {
    public let windowID: UInt64
    public let title: String
    public let frame: CGRect
    public let isResizable: Bool
    public let scaleFactor: CGFloat

    public init(
        windowID: UInt64,
        title: String,
        frame: CGRect,
        isResizable: Bool,
        scaleFactor: CGFloat = 1.0
    ) {
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.isResizable = isResizable
        self.scaleFactor = scaleFactor
    }

    // Custom Hashable implementation since CGRect doesn't conform to Hashable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(title)
        hasher.combine(frame.origin.x)
        hasher.combine(frame.origin.y)
        hasher.combine(frame.size.width)
        hasher.combine(frame.size.height)
        hasher.combine(isResizable)
        hasher.combine(scaleFactor)
    }

    public static func == (lhs: WindowMetadata, rhs: WindowMetadata) -> Bool {
        lhs.windowID == rhs.windowID &&
        lhs.title == rhs.title &&
        lhs.frame == rhs.frame &&
        lhs.isResizable == rhs.isResizable &&
        lhs.scaleFactor == rhs.scaleFactor
    }
}

public extension WindowMetadata {
    static func == (lhs: WindowMetadata, rhs: WindowMetadata) -> Bool {
        lhs.windowID == rhs.windowID &&
        lhs.title == rhs.title &&
        lhs.isResizable == rhs.isResizable &&
        lhs.scaleFactor == rhs.scaleFactor &&
        lhs.frame.equalTo(rhs.frame)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
        hasher.combine(title)
        hasher.combine(isResizable)
        hasher.combine(scaleFactor)
        hasher.combine(Double(frame.origin.x))
        hasher.combine(Double(frame.origin.y))
        hasher.combine(Double(frame.size.width))
        hasher.combine(Double(frame.size.height))
    }
}

// MARK: - Reconnect Policy

/// Policy for automatic reconnection attempts after stream disconnection.
public struct ReconnectPolicy {
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    public var maxAttempts: Int?

    public init(
        initialDelay: TimeInterval = 0.5,
        multiplier: Double = 1.8,
        maxDelay: TimeInterval = 15,
        maxAttempts: Int? = 5
    ) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    func delay(for attempt: Int) -> TimeInterval {
        let exponent = pow(multiplier, Double(max(attempt - 1, 0)))
        return min(initialDelay * exponent, maxDelay)
    }
}

// MARK: - Internal Models

struct StreamState {
    enum Lifecycle {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    var lifecycle: Lifecycle = .disconnected
    var subscription: SpiceStreamSubscription?
    var windowID: UInt64?
    var isUserInitiatedClose = false
    var isPaused = false
}

struct SpiceStreamCloseReason: CustomStringConvertible {
    enum Code {
        case remoteClosed
        case transportError
        case authenticationFailed
        case sharedMemoryUnavailable
    }

    let code: Code
    let message: String

    var description: String {
        "\(code) - \(message)"
    }
}

struct SpiceStreamCallbacks {
    let onFrame: (Data) -> Void
    let onMetadata: (WindowMetadata) -> Void
    let onClosed: (SpiceStreamCloseReason) -> Void
    let onClipboard: (ClipboardData) -> Void
}

struct SpiceStreamSubscription {
    private let cleanupHandler: () -> Void

    init(cleanup: @escaping () -> Void) {
        cleanupHandler = cleanup
    }

    func cleanup() {
        cleanupHandler()
    }
}

enum SpiceStreamError: Error {
    case connectionFailed(String)
    case sharedMemoryUnavailable(String)
}
