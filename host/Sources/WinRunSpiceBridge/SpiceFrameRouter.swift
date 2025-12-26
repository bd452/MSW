import Foundation
import WinRunShared

/// Routes FrameReady notifications from the control channel to the appropriate window streams.
///
/// The frame router maintains a registry of active `SpiceWindowStream` instances and routes
/// incoming `FrameReadyMessage` notifications to the correct stream based on window ID.
/// It also manages the shared frame buffer reader that all streams use to read frame data.
public final class SpiceFrameRouter {
    private let logger: Logger
    private let routingQueue = DispatchQueue(label: "com.winrun.spice.frame-router")

    /// Registered window streams, keyed by window ID
    private var windowStreams: [UInt64: SpiceWindowStream] = [:]

    /// Shared frame buffer reader
    private var frameBufferReader: SharedFrameBufferReader?

    public init(logger: Logger = StandardLogger(subsystem: "SpiceFrameRouter")) {
        self.logger = logger
    }

    // MARK: - Frame Buffer Management

    /// Sets the shared frame buffer reader used by all registered window streams.
    /// - Parameter reader: The shared memory buffer reader
    public func setFrameBufferReader(_ reader: SharedFrameBufferReader?) {
        routingQueue.async {
            self.frameBufferReader = reader

            // Update all registered streams with the new reader
            for (_, stream) in self.windowStreams {
                stream.setFrameBufferReader(reader)
            }

            if reader != nil {
                self.logger.info("Frame buffer reader set, propagated to \(self.windowStreams.count) streams")
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

            // Attach the shared frame buffer reader if available
            if let reader = self.frameBufferReader {
                stream.setFrameBufferReader(reader)
            }

            self.logger.debug("Registered stream for window \(windowID)")
        }
    }

    /// Unregisters a window stream.
    /// - Parameter windowID: The window ID to unregister
    public func unregisterStream(forWindowID windowID: UInt64) {
        routingQueue.async {
            if let stream = self.windowStreams.removeValue(forKey: windowID) {
                stream.setFrameBufferReader(nil)
                self.logger.debug("Unregistered stream for window \(windowID)")
            }
        }
    }

    /// Unregisters all window streams.
    public func unregisterAllStreams() {
        routingQueue.async {
            for (_, stream) in self.windowStreams {
                stream.setFrameBufferReader(nil)
            }
            self.windowStreams.removeAll()
            self.logger.debug("Unregistered all streams")
        }
    }

    /// Returns the number of registered streams.
    public var registeredStreamCount: Int {
        routingQueue.sync { windowStreams.count }
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
}
