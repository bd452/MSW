using System.Runtime.InteropServices;

namespace WinRun.Agent.Services;

// ============================================================================
// Shared Memory Frame Buffer Protocol
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
// ============================================================================

/// <summary>
/// Magic number to identify valid shared memory buffer ("WFRM" in ASCII).
/// </summary>
public static class SharedFrameBufferConstants
{
    public const uint Magic = 0x4D524657; // "WFRM"
    public const uint Version = 1;
}

/// <summary>
/// Header structure at the start of shared memory region.
/// Total size: 64 bytes (aligned for cache efficiency).
/// </summary>
[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct SharedFrameBufferHeader
{
    /// <summary>Magic number for validation (0x4D524657 = "WFRM").</summary>
    public uint Magic;
    /// <summary>Protocol version.</summary>
    public uint Version;
    /// <summary>Total size of the shared memory region in bytes.</summary>
    public uint TotalSize;
    /// <summary>Number of frame slots in the ring buffer.</summary>
    public uint SlotCount;
    /// <summary>Size of each frame slot in bytes (including metadata).</summary>
    public uint SlotSize;
    /// <summary>Maximum frame width supported.</summary>
    public uint MaxWidth;
    /// <summary>Maximum frame height supported.</summary>
    public uint MaxHeight;
    /// <summary>Write index (next slot to write, updated by guest).</summary>
    public uint WriteIndex;
    /// <summary>Read index (next slot to read, updated by host).</summary>
    public uint ReadIndex;
    /// <summary>Flags for state signaling.</summary>
    public uint Flags;
    /// <summary>Reserved for future use (6 x uint = 24 bytes).</summary>
    public uint Reserved1, Reserved2, Reserved3, Reserved4, Reserved5, Reserved6;

    public const int Size = 64;

    /// <summary>
    /// Creates a new header with default values.
    /// </summary>
    public static SharedFrameBufferHeader Create() => new()
    {
        Magic = SharedFrameBufferConstants.Magic,
        Version = SharedFrameBufferConstants.Version
    };

    /// <summary>
    /// Whether this header is valid.
    /// </summary>
    public readonly bool IsValid =>
        Magic == SharedFrameBufferConstants.Magic &&
        Version == SharedFrameBufferConstants.Version;

    /// <summary>
    /// Number of frames available to read.
    /// </summary>
    public readonly uint AvailableFrames => WriteIndex >= ReadIndex
        ? WriteIndex - ReadIndex
        : SlotCount - ReadIndex + WriteIndex;

    /// <summary>
    /// Whether the buffer has frames available.
    /// </summary>
    public readonly bool HasFrames => WriteIndex != ReadIndex;

    /// <summary>
    /// Whether the buffer is full (no slots available for writing).
    /// </summary>
    public readonly bool IsFull => ((WriteIndex + 1) % SlotCount) == ReadIndex;
}

/// <summary>
/// Metadata for a single frame slot.
/// Size: 36 bytes (padded to 40 for alignment).
/// </summary>
[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct FrameSlotHeader
{
    /// <summary>Window ID this frame belongs to.</summary>
    public ulong WindowId;
    /// <summary>Frame sequence number.</summary>
    public uint FrameNumber;
    /// <summary>Frame width in pixels.</summary>
    public uint Width;
    /// <summary>Frame height in pixels.</summary>
    public uint Height;
    /// <summary>Bytes per row (stride) for uncompressed data.</summary>
    public uint Stride;
    /// <summary>Pixel format (matches SpicePixelFormat/PixelFormatType).</summary>
    public uint Format;
    /// <summary>Actual data size in bytes (may be compressed).</summary>
    public uint DataSize;
    /// <summary>Per-frame flags (compression, key frame, etc.).</summary>
    public FrameSlotFlags Flags;

    public const int Size = 36;
}

/// <summary>
/// Per-frame slot flags.
/// </summary>
[Flags]
public enum FrameSlotFlags : uint
{
    None = 0,
    /// <summary>Frame data is LZ4 compressed.</summary>
    Compressed = 1 << 0,
    /// <summary>Frame is a key frame (not a delta).</summary>
    KeyFrame = 1 << 1
}

/// <summary>
/// Flags for SharedFrameBufferHeader.Flags field.
/// </summary>
[Flags]
public enum SharedFrameBufferFlags : uint
{
    None = 0,
    /// <summary>Guest is actively writing frames.</summary>
    GuestActive = 1 << 0,
    /// <summary>Host is actively reading frames.</summary>
    HostActive = 1 << 1,
    /// <summary>Buffer needs reset (e.g., after resize).</summary>
    NeedsReset = 1 << 2,
    /// <summary>Frame data is compressed (LZ4).</summary>
    Compressed = 1 << 3
}

/// <summary>
/// Configuration for creating a shared frame buffer.
/// </summary>
public sealed record SharedFrameBufferConfig
{
    /// <summary>Number of frame slots in the ring buffer.</summary>
    public int SlotCount { get; init; } = 3;
    /// <summary>Maximum frame width in pixels.</summary>
    public int MaxWidth { get; init; } = 3840;
    /// <summary>Maximum frame height in pixels.</summary>
    public int MaxHeight { get; init; } = 2160;
    /// <summary>Bytes per pixel (typically 4 for BGRA).</summary>
    public int BytesPerPixel { get; init; } = 4;

    /// <summary>Size of each frame slot in bytes.</summary>
    public int SlotSize => FrameSlotHeader.Size + (MaxWidth * MaxHeight * BytesPerPixel);

    /// <summary>Total size of the shared memory region in bytes.</summary>
    public int TotalSize => SharedFrameBufferHeader.Size + (SlotCount * SlotSize);

    /// <summary>
    /// Creates a header initialized with this configuration.
    /// </summary>
    public SharedFrameBufferHeader CreateHeader() => new()
    {
        Magic = SharedFrameBufferConstants.Magic,
        Version = SharedFrameBufferConstants.Version,
        TotalSize = (uint)TotalSize,
        SlotCount = (uint)SlotCount,
        SlotSize = (uint)SlotSize,
        MaxWidth = (uint)MaxWidth,
        MaxHeight = (uint)MaxHeight,
        WriteIndex = 0,
        ReadIndex = 0,
        Flags = 0
    };
}

/// <summary>
/// Guest-side writer for the shared frame buffer.
/// Writes frames for the host to read.
/// </summary>
public sealed class SharedFrameBufferWriter : IDisposable
{
    private readonly IAgentLogger _logger;
    private nint _memoryPointer;
    private int _memorySize;
    private bool _disposed;
    private bool _ownsMemory;

    public SharedFrameBufferWriter(IAgentLogger logger)
    {
        _logger = logger;
    }

    /// <summary>
    /// Whether the buffer is initialized and ready for writing.
    /// </summary>
    public bool IsInitialized => _memoryPointer != IntPtr.Zero;

    /// <summary>
    /// Initializes the writer with an existing memory region.
    /// </summary>
    /// <param name="pointer">Pointer to the shared memory region.</param>
    /// <param name="size">Size of the memory region in bytes.</param>
    /// <param name="ownsMemory">Whether this writer should free memory on dispose.</param>
    public void Initialize(nint pointer, int size, bool ownsMemory = false)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        _memoryPointer = pointer;
        _memorySize = size;
        _ownsMemory = ownsMemory;

        _logger.Info($"Shared frame buffer initialized: {size} bytes at 0x{pointer:X}");
    }

    /// <summary>
    /// Initializes the buffer with a new header using the given configuration.
    /// Call this after Initialize() to set up the buffer structure.
    /// </summary>
    public void InitializeHeader(SharedFrameBufferConfig config)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_memoryPointer == IntPtr.Zero)
        {
            throw new InvalidOperationException("Buffer not initialized");
        }

        if (_memorySize < config.TotalSize)
        {
            throw new ArgumentException(
                $"Buffer too small: need {config.TotalSize} bytes, have {_memorySize}");
        }

        var header = config.CreateHeader();
        Marshal.StructureToPtr(header, _memoryPointer, false);

        _logger.Info($"Buffer header initialized: {config.SlotCount} slots, {config.MaxWidth}x{config.MaxHeight} max");
    }

    /// <summary>
    /// Reads the current buffer header.
    /// </summary>
    public SharedFrameBufferHeader ReadHeader()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        return _memoryPointer == IntPtr.Zero
            ? throw new InvalidOperationException("Buffer not initialized")
            : Marshal.PtrToStructure<SharedFrameBufferHeader>(_memoryPointer);
    }

    /// <summary>
    /// Writes a frame to the next available slot in the ring buffer.
    /// </summary>
    /// <param name="windowId">Window ID this frame belongs to.</param>
    /// <param name="frameNumber">Frame sequence number.</param>
    /// <param name="width">Frame width in pixels.</param>
    /// <param name="height">Frame height in pixels.</param>
    /// <param name="stride">Bytes per row (uncompressed).</param>
    /// <param name="format">Pixel format.</param>
    /// <param name="data">Frame pixel data (may be compressed).</param>
    /// <param name="isCompressed">Whether the data is LZ4 compressed.</param>
    /// <returns>The slot index where the frame was written, or -1 if buffer is full.</returns>
    public int WriteFrame(
        ulong windowId,
        uint frameNumber,
        int width,
        int height,
        int stride,
        PixelFormatType format,
        ReadOnlySpan<byte> data,
        bool isCompressed = false)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_memoryPointer == IntPtr.Zero)
        {
            throw new InvalidOperationException("Buffer not initialized");
        }

        var header = ReadHeader();

        // Check if buffer is full
        var nextWrite = (header.WriteIndex + 1) % header.SlotCount;
        if (nextWrite == header.ReadIndex)
        {
            _logger.Warn("Shared frame buffer is full, dropping frame");
            return -1;
        }

        // Check if frame fits in slot
        if (data.Length > (int)header.SlotSize - FrameSlotHeader.Size)
        {
            _logger.Error($"Frame data too large: {data.Length} bytes, slot capacity: {header.SlotSize - FrameSlotHeader.Size}");
            return -1;
        }

        var slotIndex = (int)header.WriteIndex;
        var slotOffset = SharedFrameBufferHeader.Size + (slotIndex * (int)header.SlotSize);

        // Build slot flags
        var flags = FrameSlotFlags.KeyFrame; // All frames are key frames until delta compression
        if (isCompressed)
        {
            flags |= FrameSlotFlags.Compressed;
        }

        // Write frame slot header
        var slotHeader = new FrameSlotHeader
        {
            WindowId = windowId,
            FrameNumber = frameNumber,
            Width = (uint)width,
            Height = (uint)height,
            Stride = (uint)stride,
            Format = (uint)format,
            DataSize = (uint)data.Length,
            Flags = flags
        };

        Marshal.StructureToPtr(slotHeader, _memoryPointer + slotOffset, false);

        // Write frame data
        var dataOffset = slotOffset + FrameSlotHeader.Size;
        unsafe
        {
            fixed (byte* dataPtr = data)
            {
                Buffer.MemoryCopy(dataPtr, (void*)(_memoryPointer + dataOffset), data.Length, data.Length);
            }
        }

        // Update write index (atomic operation for thread safety)
        var headerPtr = _memoryPointer;
        var writeIndexOffset = Marshal.OffsetOf<SharedFrameBufferHeader>(nameof(SharedFrameBufferHeader.WriteIndex));
        Marshal.WriteInt32(headerPtr + (int)writeIndexOffset, (int)nextWrite);

        var compressedStr = isCompressed ? " (compressed)" : "";
        _logger.Debug($"Wrote frame {frameNumber} for window {windowId} to slot {slotIndex}: {width}x{height}, {data.Length} bytes{compressedStr}");

        return slotIndex;
    }

    /// <summary>
    /// Signals that the guest is actively writing.
    /// </summary>
    public void SetGuestActive(bool active)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_memoryPointer == IntPtr.Zero)
        {
            return;
        }

        var header = ReadHeader();
        var flags = (SharedFrameBufferFlags)header.Flags;

        if (active)
        {
            flags |= SharedFrameBufferFlags.GuestActive;
        }
        else
        {
            flags &= ~SharedFrameBufferFlags.GuestActive;
        }

        var flagsOffset = Marshal.OffsetOf<SharedFrameBufferHeader>(nameof(SharedFrameBufferHeader.Flags));
        Marshal.WriteInt32(_memoryPointer + (int)flagsOffset, (int)flags);
    }

    /// <summary>
    /// Checks if the host is actively reading.
    /// </summary>
    public bool IsHostActive()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_memoryPointer == IntPtr.Zero)
        {
            return false;
        }

        var header = ReadHeader();
        return ((SharedFrameBufferFlags)header.Flags).HasFlag(SharedFrameBufferFlags.HostActive);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_ownsMemory && _memoryPointer != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(_memoryPointer);
        }

        _memoryPointer = IntPtr.Zero;
    }
}

/// <summary>
/// Lightweight notification that a frame is ready in shared memory.
/// Sent via vsock/control channel to notify host to read from shared memory.
/// </summary>
public sealed record FrameReadyMessage : GuestMessage
{
    /// <summary>Window ID the frame belongs to.</summary>
    public required ulong WindowId { get; init; }
    /// <summary>Slot index in the shared memory buffer.</summary>
    public required uint SlotIndex { get; init; }
    /// <summary>Frame sequence number for ordering.</summary>
    public required uint FrameNumber { get; init; }
    /// <summary>Whether this is a key frame (full frame vs delta).</summary>
    public bool IsKeyFrame { get; init; } = true;
}
