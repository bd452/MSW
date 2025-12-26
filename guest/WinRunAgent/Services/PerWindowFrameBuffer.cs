using System.Runtime.InteropServices;

namespace WinRun.Agent.Services;

// ============================================================================
// Per-Window Frame Buffer Configuration and Management
//
// Supports two modes:
// 1. Uncompressed: Exact allocation based on frame dimensions
// 2. Compressed: Tranche-based allocation with size buckets
// ============================================================================

/// <summary>
/// Frame buffer allocation mode.
/// </summary>
public enum FrameBufferMode
{
    /// <summary>
    /// Uncompressed frames with exact allocation.
    /// Buffer sized exactly for frame dimensions. Reallocates on resize.
    /// Lowest latency, higher memory usage.
    /// </summary>
    Uncompressed,

    /// <summary>
    /// Compressed frames with tranche-based allocation.
    /// Buffer sized to tranche buckets. Reallocates when frame exceeds tranche.
    /// Higher latency, lower memory usage.
    /// </summary>
    Compressed
}

/// <summary>
/// Configuration for per-window frame buffers.
/// </summary>
public sealed record PerWindowBufferConfig
{
    /// <summary>Buffer allocation mode.</summary>
    public FrameBufferMode Mode { get; init; } = FrameBufferMode.Uncompressed;

    /// <summary>Number of frame slots per window buffer.</summary>
    public int SlotsPerWindow { get; init; } = 3;

    /// <summary>Bytes per pixel (typically 4 for BGRA).</summary>
    public int BytesPerPixel { get; init; } = 4;

    /// <summary>
    /// Size tranches for compressed mode (in bytes).
    /// Frames are allocated to the smallest tranche that fits.
    /// </summary>
    public int[] CompressedTranches { get; init; } =
    [
        3 * 1024 * 1024,    // 3 MB - small windows, typical desktop
        8 * 1024 * 1024,    // 8 MB - 1080p compressed
        20 * 1024 * 1024,   // 20 MB - 1440p/4K compressed typical
        50 * 1024 * 1024    // 50 MB - 4K compressed worst case
    ];

    /// <summary>
    /// Headroom multiplier for exact allocation.
    /// Adds buffer space for slight size variations.
    /// </summary>
    public double ExactAllocationHeadroom { get; init; } = 1.0; // No headroom by default
}

/// <summary>
/// Manages frame buffer allocation for a single window.
/// </summary>
public sealed class WindowFrameBuffer : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly PerWindowBufferConfig _config;
    private readonly ulong _windowId;

    private nint _bufferPointer;
    private int _bufferSize;
    private int _slotSize;
    private int _currentTrancheIndex = -1;
    private int _expectedFrameSize;
    private bool _disposed;

    // Ring buffer state
    private int _writeIndex;
    private int _readIndex;

    public WindowFrameBuffer(
        ulong windowId,
        PerWindowBufferConfig config,
        IAgentLogger logger)
    {
        _windowId = windowId;
        _config = config;
        _logger = logger;
    }

    /// <summary>Window ID this buffer belongs to.</summary>
    public ulong WindowId => _windowId;

    /// <summary>Whether the buffer is allocated and ready.</summary>
    public bool IsAllocated => _bufferPointer != IntPtr.Zero;

    /// <summary>Current buffer size in bytes.</summary>
    public int BufferSize => _bufferSize;

    /// <summary>Current slot size in bytes.</summary>
    public int SlotSize => _slotSize;

    /// <summary>Number of slots in this buffer.</summary>
    public int SlotCount => _config.SlotsPerWindow;

    /// <summary>
    /// Ensures the buffer is allocated for the given frame size.
    /// Returns true if reallocation occurred.
    /// </summary>
    public bool EnsureAllocated(int width, int height, int actualDataSize)
    {
        var rawFrameSize = width * height * _config.BytesPerPixel;

        return _config.Mode switch
        {
            FrameBufferMode.Uncompressed => EnsureExactAllocation(rawFrameSize),
            FrameBufferMode.Compressed => EnsureTrancheAllocation(actualDataSize),
            _ => throw new ArgumentOutOfRangeException()
        };
    }

    /// <summary>
    /// Writes a frame to the next available slot.
    /// </summary>
    /// <returns>Slot index written to, or -1 if buffer full.</returns>
    public int WriteFrame(FrameSlotHeader header, ReadOnlySpan<byte> data)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_bufferPointer == IntPtr.Zero)
        {
            throw new InvalidOperationException("Buffer not allocated");
        }

        // Check if buffer is full
        var nextWrite = (_writeIndex + 1) % _config.SlotsPerWindow;
        if (nextWrite == _readIndex)
        {
            return -1; // Buffer full
        }

        // Check if frame fits
        if (data.Length > _slotSize - FrameSlotHeader.Size)
        {
            _logger.Error($"Frame too large for slot: {data.Length} > {_slotSize - FrameSlotHeader.Size}");
            return -1;
        }

        var slotOffset = _writeIndex * _slotSize;

        // Write header
        Marshal.StructureToPtr(header, _bufferPointer + slotOffset, false);

        // Write data
        var dataOffset = slotOffset + FrameSlotHeader.Size;
        unsafe
        {
            fixed (byte* dataPtr = data)
            {
                Buffer.MemoryCopy(dataPtr, (void*)(_bufferPointer + dataOffset), data.Length, data.Length);
            }
        }

        var writtenSlot = _writeIndex;
        _writeIndex = nextWrite;

        return writtenSlot;
    }

    /// <summary>
    /// Advances the read index (called by host via notification).
    /// </summary>
    public void AdvanceReadIndex()
    {
        if (_writeIndex != _readIndex)
        {
            _readIndex = (_readIndex + 1) % _config.SlotsPerWindow;
        }
    }

    /// <summary>
    /// Gets the buffer pointer for host mapping.
    /// </summary>
    public nint GetBufferPointer() => _bufferPointer;

    private bool EnsureExactAllocation(int rawFrameSize)
    {
        var requiredSlotSize = FrameSlotHeader.Size + (int)(rawFrameSize * _config.ExactAllocationHeadroom);

        // Check if current allocation is exact match
        if (_bufferPointer != IntPtr.Zero && _expectedFrameSize == rawFrameSize)
        {
            return false; // No reallocation needed
        }

        // Need to (re)allocate
        Reallocate(requiredSlotSize);
        _expectedFrameSize = rawFrameSize;

        _logger.Debug($"Window {_windowId}: Exact allocation for {rawFrameSize} bytes ({_bufferSize / 1024} KB total)");
        return true;
    }

    private bool EnsureTrancheAllocation(int compressedDataSize)
    {
        var requiredSlotSize = FrameSlotHeader.Size + compressedDataSize;
        var trancheIndex = FindTrancheIndex(requiredSlotSize);

        // Check if current tranche is sufficient
        if (_bufferPointer != IntPtr.Zero && _currentTrancheIndex >= trancheIndex)
        {
            return false; // Current tranche is big enough
        }

        // Need to allocate larger tranche
        var trancheSize = _config.CompressedTranches[trancheIndex];
        Reallocate(trancheSize);
        _currentTrancheIndex = trancheIndex;

        _logger.Debug($"Window {_windowId}: Tranche {trancheIndex} allocation ({trancheSize / 1024} KB/slot, {_bufferSize / 1024} KB total)");
        return true;
    }

    private int FindTrancheIndex(int requiredSize)
    {
        for (var i = 0; i < _config.CompressedTranches.Length; i++)
        {
            if (_config.CompressedTranches[i] >= requiredSize)
            {
                return i;
            }
        }

        // Exceeds all tranches - use largest
        _logger.Warn($"Frame size {requiredSize} exceeds all tranches, using largest");
        return _config.CompressedTranches.Length - 1;
    }

    private void Reallocate(int slotSize)
    {
        // Free existing buffer
        if (_bufferPointer != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(_bufferPointer);
            _bufferPointer = IntPtr.Zero;
        }

        _slotSize = slotSize;
        _bufferSize = slotSize * _config.SlotsPerWindow;

        _bufferPointer = Marshal.AllocHGlobal(_bufferSize);

        // Zero the buffer
        unsafe
        {
            new Span<byte>((void*)_bufferPointer, _bufferSize).Clear();
        }

        // Reset ring buffer indices
        _writeIndex = 0;
        _readIndex = 0;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_bufferPointer != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(_bufferPointer);
            _bufferPointer = IntPtr.Zero;
        }
    }
}

/// <summary>
/// Manages per-window frame buffers for all tracked windows.
/// </summary>
public sealed class PerWindowBufferManager : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly PerWindowBufferConfig _config;
    private readonly Dictionary<ulong, WindowFrameBuffer> _buffers = [];
    private readonly object _lock = new();
    private bool _disposed;

    public PerWindowBufferManager(
        PerWindowBufferConfig config,
        IAgentLogger logger)
    {
        _config = config;
        _logger = logger;

        _logger.Info($"PerWindowBufferManager created: mode={config.Mode}, slots={config.SlotsPerWindow}");
    }

    /// <summary>
    /// Gets or creates a buffer for the specified window.
    /// </summary>
    public WindowFrameBuffer GetOrCreateBuffer(ulong windowId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        lock (_lock)
        {
            if (_buffers.TryGetValue(windowId, out var existing))
            {
                return existing;
            }

            var buffer = new WindowFrameBuffer(windowId, _config, _logger);
            _buffers[windowId] = buffer;
            return buffer;
        }
    }

    /// <summary>
    /// Removes and disposes the buffer for the specified window.
    /// </summary>
    public void RemoveBuffer(ulong windowId)
    {
        lock (_lock)
        {
            if (_buffers.TryGetValue(windowId, out var buffer))
            {
                buffer.Dispose();
                _buffers.Remove(windowId);
                _logger.Debug($"Removed buffer for window {windowId}");
            }
        }
    }

    /// <summary>
    /// Gets statistics about buffer allocation.
    /// </summary>
    public BufferManagerStats GetStats()
    {
        lock (_lock)
        {
            var totalMemory = 0L;
            var allocatedCount = 0;

            foreach (var buffer in _buffers.Values)
            {
                if (buffer.IsAllocated)
                {
                    totalMemory += buffer.BufferSize;
                    allocatedCount++;
                }
            }

            return new BufferManagerStats
            {
                WindowCount = _buffers.Count,
                AllocatedBufferCount = allocatedCount,
                TotalMemoryBytes = totalMemory,
                Mode = _config.Mode
            };
        }
    }

    /// <summary>
    /// Cleans up buffers for windows that no longer exist.
    /// </summary>
    public void CleanupStaleBuffers(IEnumerable<ulong> activeWindowIds)
    {
        var activeSet = activeWindowIds.ToHashSet();

        lock (_lock)
        {
            var staleIds = _buffers.Keys.Where(id => !activeSet.Contains(id)).ToList();

            foreach (var id in staleIds)
            {
                if (_buffers.TryGetValue(id, out var buffer))
                {
                    buffer.Dispose();
                    _buffers.Remove(id);
                }
            }

            if (staleIds.Count > 0)
            {
                _logger.Debug($"Cleaned up {staleIds.Count} stale window buffers");
            }
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        lock (_lock)
        {
            foreach (var buffer in _buffers.Values)
            {
                buffer.Dispose();
            }

            _buffers.Clear();
        }
    }
}

/// <summary>
/// Statistics about buffer manager state.
/// </summary>
public sealed record BufferManagerStats
{
    public int WindowCount { get; init; }
    public int AllocatedBufferCount { get; init; }
    public long TotalMemoryBytes { get; init; }
    public FrameBufferMode Mode { get; init; }

    public string TotalMemoryFormatted => TotalMemoryBytes switch
    {
        < 1024 => $"{TotalMemoryBytes} B",
        < 1024 * 1024 => $"{TotalMemoryBytes / 1024} KB",
        _ => $"{TotalMemoryBytes / (1024 * 1024)} MB"
    };

    public override string ToString() =>
        $"Mode={Mode}, Windows={WindowCount}, Allocated={AllocatedBufferCount}, Memory={TotalMemoryFormatted}";
}
