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

    /// Shared memory region base pointer (for per-window buffer mapping)
    private var sharedMemoryBasePointer: UnsafeMutableRawPointer?

    /// Shared memory region size in bytes
    private var sharedMemorySize: Int = 0

    public init(logger: Logger = StandardLogger(subsystem: "SpiceFrameRouter")) {
        self.logger = logger
    }

    // MARK: - Shared Memory Region Configuration

    /// Sets the shared memory region for per-window buffer mapping.
    /// Call this after the VM's shared memory region is initialized.
    /// - Parameters:
    ///   - basePointer: Base pointer to the shared memory region
    ///   - size: Size of the shared memory region in bytes
    public func setSharedMemoryRegion(basePointer: UnsafeMutableRawPointer, size: Int) {
        routingQueue.async {
            self.sharedMemoryBasePointer = basePointer
            self.sharedMemorySize = size
            self.logger.info("Shared memory region configured: \(size / 1024 / 1024) MB")

            // Re-process any existing buffer allocations that use shared memory
            // This handles the case where allocations arrived before the region was set
            for (windowId, info) in self.windowBufferInfo where info.usesSharedMemory {
                self.createReaderForBuffer(windowId: windowId, info: info)
            }
        }
    }

    /// Clears the shared memory region reference.
    /// Call this when the VM is stopped or the region is deallocated.
    public func clearSharedMemoryRegion() {
        routingQueue.async {
            self.sharedMemoryBasePointer = nil
            self.sharedMemorySize = 0
            self.logger.debug("Shared memory region cleared")
        }
    }

    /// Whether a shared memory region has been configured.
    public var hasSharedMemoryRegion: Bool {
        routingQueue.sync { sharedMemoryBasePointer != nil }
    }

    // MARK: - Per-Window Buffer Management

    /// Handles a window buffer allocation notification from the guest.
    /// Creates or updates the buffer reader for the specified window.
    /// - Parameter notification: The buffer allocation message
    public func handleBufferAllocation(_ notification: WindowBufferAllocatedMessage) {
        routingQueue.async {
            let windowId = notification.windowId

            // Store buffer info
            let info = WindowBufferInfo(
                bufferPointer: notification.bufferPointer,
                bufferSize: Int(notification.bufferSize),
                slotSize: Int(notification.slotSize),
                slotCount: Int(notification.slotCount),
                isCompressed: notification.isCompressed,
                usesSharedMemory: notification.usesSharedMemory
            )
            self.windowBufferInfo[windowId] = info

            let action = notification.isReallocation ? "reallocated" : "allocated"
            let memoryType = notification.usesSharedMemory ? "shared" : "local"
            self.logger.info(
                "Window \(windowId) buffer \(action): " +
                "\(notification.bufferSize / 1024) KB, \(notification.slotCount) slots (\(memoryType))"
            )

            // Create reader for shared memory buffers
            if notification.usesSharedMemory {
                self.createReaderForBuffer(windowId: windowId, info: info)
            }
        }
    }

    /// Creates a SharedFrameBufferReader for a per-window buffer and attaches it to the stream.
    /// This is called when a buffer allocation is received or when the shared memory region is set.
    /// - Parameters:
    ///   - windowId: The window ID
    ///   - info: The buffer info containing offset and size
    private func createReaderForBuffer(windowId: UInt64, info: WindowBufferInfo) {
        // Must be called on routingQueue
        guard info.usesSharedMemory else {
            logger.debug("Skipping reader creation for window \(windowId) - not using shared memory")
            return
        }

        guard let basePointer = sharedMemoryBasePointer else {
            logger.debug(
                "Deferring reader creation for window \(windowId) - " +
                "shared memory region not yet configured"
            )
            return
        }

        // Validate that the buffer offset + size fits within the shared region
        let offset = Int(info.bufferPointer)
        let endOffset = offset + info.bufferSize

        guard offset >= 0 && endOffset <= sharedMemorySize else {
            logger.error(
                "Invalid buffer allocation for window \(windowId): " +
                "offset \(offset) + size \(info.bufferSize) exceeds region size \(sharedMemorySize)"
            )
            return
        }

        // Calculate the host pointer for this buffer
        let bufferPointer = basePointer.advanced(by: offset)

        // Create the reader for this per-window buffer
        let reader = SharedFrameBufferReader(
            pointer: bufferPointer,
            size: info.bufferSize,
            ownsMemory: false, // Shared memory region owns the memory
            logger: logger
        )

        // Store the reader
        windowBufferReaders[windowId] = reader

        logger.debug(
            "Created buffer reader for window \(windowId): " +
            "offset=\(offset), size=\(info.bufferSize / 1024) KB"
        )

        // Attach reader to the stream if registered
        if let stream = windowStreams[windowId] {
            stream.setFrameBufferReader(reader)
            logger.debug("Attached buffer reader to stream for window \(windowId)")
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

                // Attach existing reader to the stream
                if let reader = self.windowBufferReaders[windowID] {
                    stream.setFrameBufferReader(reader)
                    self.logger.debug("Attached existing buffer reader to stream for window \(windowID)")
                } else if bufferInfo.usesSharedMemory && self.sharedMemoryBasePointer != nil {
                    // Buffer uses shared memory but reader wasn't created yet - create it now
                    self.createReaderForBuffer(windowId: windowID, info: bufferInfo)
                }
            } else {
                self.logger.debug("Registered stream for window \(windowID), awaiting buffer allocation")
            }
        }
    }

    /// Unregisters a window stream.
    /// - Parameter windowID: The window ID to unregister
    public func unregisterStream(forWindowID windowID: UInt64) {
        routingQueue.async {
            // Clear the reader from the stream before removing
            if let stream = self.windowStreams[windowID] {
                stream.setFrameBufferReader(nil)
            }

            if self.windowStreams.removeValue(forKey: windowID) != nil {
                self.logger.debug("Unregistered stream for window \(windowID)")
            }

            // Also clean up buffer reader if present
            if self.windowBufferReaders.removeValue(forKey: windowID) != nil {
                self.logger.debug("Cleaned up buffer reader for window \(windowID)")
            }

            // Clean up buffer info
            self.windowBufferInfo.removeValue(forKey: windowID)
        }
    }

    /// Unregisters all window streams.
    public func unregisterAllStreams() {
        routingQueue.async {
            // Clear readers from all streams
            for (_, stream) in self.windowStreams {
                stream.setFrameBufferReader(nil)
            }

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

    /// Returns the number of active buffer readers.
    public var activeReaderCount: Int {
        routingQueue.sync { windowBufferReaders.count }
    }

    /// Gets the buffer reader for a specific window (for testing).
    /// - Parameter windowID: The window ID
    /// - Returns: The buffer reader if created, nil otherwise
    public func bufferReader(forWindowID windowID: UInt64) -> SharedFrameBufferReader? {
        routingQueue.sync { windowBufferReaders[windowID] }
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
    /// Buffer location. When `usesSharedMemory` is true, this is an offset into
    /// the shared memory region. Otherwise, it's a guest memory pointer.
    public let bufferPointer: UInt64
    /// Total buffer size in bytes
    public let bufferSize: Int
    /// Size of each slot in bytes
    public let slotSize: Int
    /// Number of slots in the buffer
    public let slotCount: Int
    /// Whether frames in this buffer are compressed
    public let isCompressed: Bool
    /// Whether this buffer uses shared memory
    public let usesSharedMemory: Bool

    public init(
        bufferPointer: UInt64,
        bufferSize: Int,
        slotSize: Int,
        slotCount: Int,
        isCompressed: Bool,
        usesSharedMemory: Bool = false
    ) {
        self.bufferPointer = bufferPointer
        self.bufferSize = bufferSize
        self.slotSize = slotSize
        self.slotCount = slotCount
        self.isCompressed = isCompressed
        self.usesSharedMemory = usesSharedMemory
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
