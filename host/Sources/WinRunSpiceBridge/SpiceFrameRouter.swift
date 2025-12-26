import Foundation
import WinRunShared

/// Routes FrameReady notifications from the control channel to the appropriate window streams.
///
/// The frame router maintains a registry of active `SpiceWindowStream` instances and routes
/// incoming `FrameReadyMessage` notifications to the correct stream based on window ID.
/// It manages per-window frame buffer readers for reading frame data from shared memory.
public final class SpiceFrameRouter {
    private let logger: Logger
    private let routingQueue = DispatchQueue(label: "com.winrun.spice.frame-router")

    /// Registered window streams, keyed by window ID
    private var windowStreams: [UInt64: SpiceWindowStream] = [:]

    /// Per-window frame buffer readers, keyed by window ID
    private var windowBufferReaders: [UInt64: SharedFrameBufferReader] = [:]

    /// Per-window buffer info for tracking allocations
    private var windowBufferInfo: [UInt64: WindowBufferInfo] = [:]

    public init(logger: Logger = StandardLogger(subsystem: "SpiceFrameRouter")) {
        self.logger = logger
    }

    // MARK: - Per-Window Buffer Management

    /// Handles a window buffer allocation notification from the guest.
    /// Creates or updates the buffer reader for the specified window.
    /// - Parameter notification: The buffer allocation message
    public func handleBufferAllocation(_ notification: WindowBufferAllocatedMessage) {
        routingQueue.async {
            let windowId = notification.windowId

            // Store buffer info
            self.windowBufferInfo[windowId] = WindowBufferInfo(
                bufferPointer: notification.bufferPointer,
                bufferSize: Int(notification.bufferSize),
                slotSize: Int(notification.slotSize),
                slotCount: Int(notification.slotCount),
                isCompressed: notification.isCompressed
            )

            // Note: In a real implementation, we would map the guest's buffer pointer
            // to host memory. For now, we log the allocation and the stream will
            // need to handle reading from the appropriate location.
            let action = notification.isReallocation ? "reallocated" : "allocated"
            self.logger.info(
                "Window \(windowId) buffer \(action): " +
                "\(notification.bufferSize / 1024) KB, \(notification.slotCount) slots"
            )

            // If there's a stream registered for this window, notify it of the new buffer
            if let stream = self.windowStreams[windowId] {
                // In a full implementation, we would create a reader for this buffer
                // and attach it to the stream. For now, the stream uses its own reader.
                self.logger.debug("Stream registered for window \(windowId), buffer info updated")
                _ = stream // Silence unused warning
            }
        }
    }

    /// Gets buffer info for a specific window.
    /// - Parameter windowID: The window ID
    /// - Returns: Buffer info if allocated, nil otherwise
    public func bufferInfo(forWindowID windowID: UInt64) -> WindowBufferInfo? {
        routingQueue.sync { windowBufferInfo[windowID] }
    }

    // MARK: - Legacy Shared Buffer Support

    /// Sets a shared frame buffer reader (legacy mode for single shared buffer).
    /// - Parameter reader: The shared memory buffer reader
    @available(*, deprecated, message: "Use per-window buffer allocation instead")
    public func setFrameBufferReader(_ reader: SharedFrameBufferReader?) {
        routingQueue.async {
            // In legacy mode, apply the same reader to all streams
            for (_, stream) in self.windowStreams {
                stream.setFrameBufferReader(reader)
            }

            if reader != nil {
                self.logger.info("Legacy shared buffer reader set for \(self.windowStreams.count) streams")
            }
        }
    }

    // MARK: - Stream Registration

    /// Registers a window stream for frame routing.
    /// - Parameters:
    ///   - stream: The window stream to register
    ///   - windowID: The window ID to associate with the stream
    public func registerStream(_ stream: SpiceWindowStream, forWindowID windowID: UInt64) {
        routingQueue.async {
            self.windowStreams[windowID] = stream

            // If we have buffer info for this window, the stream can use it
            if let bufferInfo = self.windowBufferInfo[windowID] {
                self.logger.debug(
                    "Registered stream for window \(windowID) with existing buffer: " +
                    "\(bufferInfo.bufferSize / 1024) KB"
                )
            } else {
                self.logger.debug("Registered stream for window \(windowID), awaiting buffer allocation")
            }
        }
    }

    /// Unregisters a window stream.
    /// - Parameter windowID: The window ID to unregister
    public func unregisterStream(forWindowID windowID: UInt64) {
        routingQueue.async {
            if self.windowStreams.removeValue(forKey: windowID) != nil {
                self.logger.debug("Unregistered stream for window \(windowID)")
            }

            // Also clean up buffer reader if present
            if self.windowBufferReaders.removeValue(forKey: windowID) != nil {
                self.logger.debug("Cleaned up buffer reader for window \(windowID)")
            }
        }
    }

    /// Unregisters all window streams.
    public func unregisterAllStreams() {
        routingQueue.async {
            self.windowStreams.removeAll()
            self.windowBufferReaders.removeAll()
            self.windowBufferInfo.removeAll()
            self.logger.debug("Unregistered all streams and buffers")
        }
    }

    /// Returns the number of registered streams.
    public var registeredStreamCount: Int {
        routingQueue.sync { windowStreams.count }
    }

    /// Returns the number of allocated buffers.
    public var allocatedBufferCount: Int {
        routingQueue.sync { windowBufferInfo.count }
    }

    // MARK: - Frame Routing

    /// Routes a FrameReady notification to the appropriate window stream.
    /// - Parameter notification: The FrameReady message from the control channel
    public func routeFrameReady(_ notification: FrameReadyMessage) {
        routingQueue.async {
            guard let stream = self.windowStreams[notification.windowId] else {
                self.logger.debug("No stream registered for window \(notification.windowId), dropping frame")
                return
            }

            stream.handleFrameReady(notification)
        }
    }
}

// MARK: - Supporting Types

/// Information about a window's frame buffer allocation.
public struct WindowBufferInfo: Hashable {
    /// Guest-side pointer to the buffer
    public let bufferPointer: UInt64
    /// Total buffer size in bytes
    public let bufferSize: Int
    /// Size of each slot in bytes
    public let slotSize: Int
    /// Number of slots in the buffer
    public let slotCount: Int
    /// Whether frames in this buffer are compressed
    public let isCompressed: Bool

    public init(
        bufferPointer: UInt64,
        bufferSize: Int,
        slotSize: Int,
        slotCount: Int,
        isCompressed: Bool
    ) {
        self.bufferPointer = bufferPointer
        self.bufferSize = bufferSize
        self.slotSize = slotSize
        self.slotCount = slotCount
        self.isCompressed = isCompressed
    }
}

// MARK: - SpiceControlChannelDelegate Extension

extension SpiceFrameRouter: SpiceControlChannelDelegate {
    public func controlChannelDidConnect(_ channel: SpiceControlChannel) {
        logger.info("Control channel connected")
    }

    public func controlChannelDidDisconnect(_ channel: SpiceControlChannel) {
        logger.info("Control channel disconnected")
    }

    public func controlChannel(
        _ channel: SpiceControlChannel,
        didReceiveMessage message: Any,
        type: SpiceMessageType
    ) {
        // Handle other message types if needed
        logger.debug("Received control message: \(type)")
    }

    public func controlChannel(
        _ channel: SpiceControlChannel,
        didReceiveFrameReady notification: FrameReadyMessage
    ) {
        routeFrameReady(notification)
    }

    public func controlChannel(
        _ channel: SpiceControlChannel,
        didReceiveBufferAllocation notification: WindowBufferAllocatedMessage
    ) {
        handleBufferAllocation(notification)
    }
}
