import Foundation
import WinRunShared

// MARK: - Shared Memory Frame Buffer Protocol
//
// The shared memory region uses a ring buffer design for zero-copy frame transfer.
// Layout:
//   [Header: 64 bytes]
//   [Frame Slot 0: variable]
//   [Frame Slot 1: variable]
//   ...
//   [Frame Slot N-1: variable]
//
// The header contains synchronization state and buffer metadata.
// Each frame slot contains frame metadata followed by pixel data.

/// Magic number to identify valid shared memory buffer ("WFRM" in ASCII)
public let SharedFrameBufferMagic: UInt32 = 0x4D524657

/// Current version of the shared memory protocol
public let SharedFrameBufferVersion: UInt32 = 1

/// Header structure at the start of shared memory region.
/// Total size: 64 bytes (aligned for cache efficiency)
public struct SharedFrameBufferHeader {
    /// Magic number for validation (0x4D524657 = "WFRM")
    public var magic: UInt32
    /// Protocol version
    public var version: UInt32
    /// Total size of the shared memory region in bytes
    public var totalSize: UInt32
    /// Number of frame slots in the ring buffer
    public var slotCount: UInt32
    /// Size of each frame slot in bytes (including metadata)
    public var slotSize: UInt32
    /// Maximum frame width supported
    public var maxWidth: UInt32
    /// Maximum frame height supported
    public var maxHeight: UInt32
    /// Write index (next slot to write, updated by guest)
    public var writeIndex: UInt32
    /// Read index (next slot to read, updated by host)
    public var readIndex: UInt32
    /// Flags for state signaling
    public var flags: UInt32
    /// Reserved for future use (24 bytes = 6 x UInt32)
    public var reserved0: UInt32
    public var reserved1: UInt32
    public var reserved2: UInt32
    public var reserved3: UInt32
    public var reserved4: UInt32
    public var reserved5: UInt32

    public static let size = 64

    public init() {
        magic = SharedFrameBufferMagic
        version = SharedFrameBufferVersion
        totalSize = 0
        slotCount = 0
        slotSize = 0
        maxWidth = 0
        maxHeight = 0
        writeIndex = 0
        readIndex = 0
        flags = 0
        reserved0 = 0
        reserved1 = 0
        reserved2 = 0
        reserved3 = 0
        reserved4 = 0
        reserved5 = 0
    }

    /// Whether this header is valid
    public var isValid: Bool {
        magic == SharedFrameBufferMagic && version == SharedFrameBufferVersion
    }

    /// Number of frames available to read
    public var availableFrames: UInt32 {
        if writeIndex >= readIndex {
            return writeIndex - readIndex
        } else {
            return slotCount - readIndex + writeIndex
        }
    }

    /// Whether the buffer has frames available
    public var hasFrames: Bool {
        writeIndex != readIndex
    }
}

/// Metadata for a single frame slot.
/// Size: 36 bytes
public struct FrameSlotHeader {
    /// Window ID this frame belongs to
    public var windowId: UInt64
    /// Frame sequence number
    public var frameNumber: UInt32
    /// Frame width in pixels
    public var width: UInt32
    /// Frame height in pixels
    public var height: UInt32
    /// Bytes per row (stride) for uncompressed data
    public var stride: UInt32
    /// Pixel format (matches SpicePixelFormat)
    public var format: UInt32
    /// Actual data size in bytes (may be compressed)
    public var dataSize: UInt32
    /// Per-frame flags (compression, key frame, etc.)
    public var flags: UInt32

    public static let size = 36

    public init() {
        windowId = 0
        frameNumber = 0
        width = 0
        height = 0
        stride = 0
        format = 0
        dataSize = 0
        flags = 0
    }
}

/// Per-frame slot flags
public struct FrameSlotFlags: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Frame data is LZ4 compressed
    public static let compressed = FrameSlotFlags(rawValue: 1 << 0)
    /// Frame is a key frame (not a delta)
    public static let keyFrame = FrameSlotFlags(rawValue: 1 << 1)
}

/// Flags for SharedFrameBufferHeader.flags field
public struct SharedFrameBufferFlags: OptionSet {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Guest is actively writing frames
    public static let guestActive = SharedFrameBufferFlags(rawValue: 1 << 0)
    /// Host is actively reading frames
    public static let hostActive = SharedFrameBufferFlags(rawValue: 1 << 1)
    /// Buffer needs reset (e.g., after resize)
    public static let needsReset = SharedFrameBufferFlags(rawValue: 1 << 2)
    /// Frame data is compressed (LZ4)
    public static let compressed = SharedFrameBufferFlags(rawValue: 1 << 3)
}

// MARK: - Host-Side Frame Buffer Reader

/// Errors that can occur during shared frame buffer operations.
public enum SharedFrameBufferError: Error, CustomStringConvertible {
    case invalidMagic
    case versionMismatch(expected: UInt32, actual: UInt32)
    case bufferTooSmall(required: Int, actual: Int)
    case noFramesAvailable
    case slotIndexOutOfBounds
    case mappingFailed(String)

    public var description: String {
        switch self {
        case .invalidMagic:
            return "Invalid shared memory buffer magic number"
        case .versionMismatch(let expected, let actual):
            return "Protocol version mismatch: expected \(expected), got \(actual)"
        case .bufferTooSmall(let required, let actual):
            return "Buffer too small: need \(required) bytes, have \(actual)"
        case .noFramesAvailable:
            return "No frames available in buffer"
        case .slotIndexOutOfBounds:
            return "Frame slot index out of bounds"
        case .mappingFailed(let reason):
            return "Memory mapping failed: \(reason)"
        }
    }
}

/// A frame read from the shared memory buffer.
public struct SharedFrame {
    public let windowId: UInt64
    public let frameNumber: UInt32
    public let width: Int
    public let height: Int
    public let stride: Int
    public let format: SpicePixelFormat
    public let data: Data
    public let isCompressed: Bool

    public init(
        windowId: UInt64,
        frameNumber: UInt32,
        width: Int,
        height: Int,
        stride: Int,
        format: SpicePixelFormat,
        data: Data,
        isCompressed: Bool = false
    ) {
        self.windowId = windowId
        self.frameNumber = frameNumber
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
        self.data = data
        self.isCompressed = isCompressed
    }
}

/// Host-side reader for the shared frame buffer.
/// Reads frames written by the guest agent.
public final class SharedFrameBufferReader {
    private let memoryPointer: UnsafeMutableRawPointer
    private let memorySize: Int
    private let ownsMemory: Bool
    private let logger: Logger

    /// Creates a reader with an existing memory region.
    /// - Parameters:
    ///   - pointer: Pointer to the shared memory region
    ///   - size: Size of the memory region in bytes
    ///   - ownsMemory: Whether this reader should deallocate memory on deinit
    ///   - logger: Logger for diagnostics
    public init(
        pointer: UnsafeMutableRawPointer,
        size: Int,
        ownsMemory: Bool = false,
        logger: Logger = StandardLogger(subsystem: "SharedFrameBuffer")
    ) {
        self.memoryPointer = pointer
        self.memorySize = size
        self.ownsMemory = ownsMemory
        self.logger = logger
    }

    deinit {
        if ownsMemory {
            memoryPointer.deallocate()
        }
    }

    /// Validates the shared memory buffer header.
    public func validate() throws {
        guard memorySize >= SharedFrameBufferHeader.size else {
            throw SharedFrameBufferError.bufferTooSmall(
                required: SharedFrameBufferHeader.size,
                actual: memorySize
            )
        }

        let header = readHeader()
        guard header.magic == SharedFrameBufferMagic else {
            throw SharedFrameBufferError.invalidMagic
        }

        guard header.version == SharedFrameBufferVersion else {
            throw SharedFrameBufferError.versionMismatch(
                expected: SharedFrameBufferVersion,
                actual: header.version
            )
        }
    }

    /// Reads the buffer header.
    public func readHeader() -> SharedFrameBufferHeader {
        memoryPointer.load(as: SharedFrameBufferHeader.self)
    }

    /// Updates the read index after consuming a frame.
    private func advanceReadIndex() {
        let headerPtr = memoryPointer.assumingMemoryBound(to: SharedFrameBufferHeader.self)
        let currentRead = headerPtr.pointee.readIndex
        let slotCount = headerPtr.pointee.slotCount
        headerPtr.pointee.readIndex = (currentRead + 1) % slotCount
    }

    /// Whether frames are available to read.
    public var hasFrames: Bool {
        readHeader().hasFrames
    }

    /// Number of frames available to read.
    public var availableFrameCount: Int {
        Int(readHeader().availableFrames)
    }

    /// Reads the next available frame from the buffer.
    /// - Returns: The frame data, or nil if no frames available
    public func readNextFrame() throws -> SharedFrame? {
        let header = readHeader()

        guard header.hasFrames else {
            return nil
        }

        let slotIndex = header.readIndex
        guard slotIndex < header.slotCount else {
            throw SharedFrameBufferError.slotIndexOutOfBounds
        }

        // Calculate slot offset
        let slotOffset = SharedFrameBufferHeader.size + Int(slotIndex) * Int(header.slotSize)
        guard slotOffset + FrameSlotHeader.size <= memorySize else {
            throw SharedFrameBufferError.slotIndexOutOfBounds
        }

        // Read frame slot header
        let slotPtr = memoryPointer.advanced(by: slotOffset)
        let slotHeader = slotPtr.load(as: FrameSlotHeader.self)

        // Read frame data
        let dataOffset = slotOffset + FrameSlotHeader.size
        let dataSize = Int(slotHeader.dataSize)
        guard dataOffset + dataSize <= memorySize else {
            throw SharedFrameBufferError.bufferTooSmall(
                required: dataOffset + dataSize,
                actual: memorySize
            )
        }

        let dataPtr = memoryPointer.advanced(by: dataOffset)
        let data = Data(bytes: dataPtr, count: dataSize)

        let slotFlags = FrameSlotFlags(rawValue: slotHeader.flags)
        let format = SpicePixelFormat(rawValue: UInt8(truncatingIfNeeded: slotHeader.format)) ?? .bgra32

        let frame = SharedFrame(
            windowId: slotHeader.windowId,
            frameNumber: slotHeader.frameNumber,
            width: Int(slotHeader.width),
            height: Int(slotHeader.height),
            stride: Int(slotHeader.stride),
            format: format,
            data: data,
            isCompressed: slotFlags.contains(.compressed)
        )

        // Advance read pointer
        advanceReadIndex()

        logger.debug("Read frame \(slotHeader.frameNumber) for window \(slotHeader.windowId): \(slotHeader.width)x\(slotHeader.height)")

        return frame
    }

    /// Signals that the host is actively reading.
    public func setHostActive(_ active: Bool) {
        let headerPtr = memoryPointer.assumingMemoryBound(to: SharedFrameBufferHeader.self)
        var flags = SharedFrameBufferFlags(rawValue: headerPtr.pointee.flags)
        if active {
            flags.insert(.hostActive)
        } else {
            flags.remove(.hostActive)
        }
        headerPtr.pointee.flags = flags.rawValue
    }
}

// MARK: - Buffer Configuration

/// Configuration for creating a shared frame buffer.
public struct SharedFrameBufferConfig {
    /// Number of frame slots in the ring buffer
    public let slotCount: Int
    /// Maximum frame width in pixels
    public let maxWidth: Int
    /// Maximum frame height in pixels
    public let maxHeight: Int
    /// Bytes per pixel (typically 4 for BGRA)
    public let bytesPerPixel: Int

    public init(
        slotCount: Int = 3,
        maxWidth: Int = 3840,
        maxHeight: Int = 2160,
        bytesPerPixel: Int = 4
    ) {
        self.slotCount = slotCount
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.bytesPerPixel = bytesPerPixel
    }

    /// Size of each frame slot in bytes
    public var slotSize: Int {
        FrameSlotHeader.size + maxWidth * maxHeight * bytesPerPixel
    }

    /// Total size of the shared memory region in bytes
    public var totalSize: Int {
        SharedFrameBufferHeader.size + slotCount * slotSize
    }

    /// Creates a header initialized with this configuration
    public func createHeader() -> SharedFrameBufferHeader {
        var header = SharedFrameBufferHeader()
        header.totalSize = UInt32(totalSize)
        header.slotCount = UInt32(slotCount)
        header.slotSize = UInt32(slotSize)
        header.maxWidth = UInt32(maxWidth)
        header.maxHeight = UInt32(maxHeight)
        return header
    }
}

// MARK: - FrameReady Notification Message

/// Lightweight notification that a frame is ready in shared memory.
/// Sent via vsock/control channel to notify host to read from shared memory.
public struct FrameReadyMessage: GuestMessage {
    public let timestamp: Int64
    /// Window ID the frame belongs to
    public let windowId: UInt64
    /// Slot index in the shared memory buffer
    public let slotIndex: UInt32
    /// Frame sequence number for ordering
    public let frameNumber: UInt32
    /// Whether this is a key frame (full frame vs delta)
    public let isKeyFrame: Bool

    public init(
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        windowId: UInt64,
        slotIndex: UInt32,
        frameNumber: UInt32,
        isKeyFrame: Bool = true
    ) {
        self.timestamp = timestamp
        self.windowId = windowId
        self.slotIndex = slotIndex
        self.frameNumber = frameNumber
        self.isKeyFrame = isKeyFrame
    }
}
