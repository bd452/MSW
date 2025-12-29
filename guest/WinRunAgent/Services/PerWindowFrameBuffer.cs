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
    private readonly SharedMemoryAllocator? _sharedAllocator;

    private nint _bufferPointer;
    private int _currentTrancheIndex = -1;
    private int _expectedFrameSize;
    private bool _disposed;
    private SharedAllocation _currentAllocation;

    // Ring buffer state
    private int _writeIndex;
    private int _readIndex;

    public WindowFrameBuffer(
        ulong windowId,
        PerWindowBufferConfig config,
        IAgentLogger logger,
        SharedMemoryAllocator? sharedAllocator = null)
    {
        WindowId = windowId;
        _config = config;
        _logger = logger;
        _sharedAllocator = sharedAllocator;
    }

    /// <summary>Window ID this buffer belongs to.</summary>
    public ulong WindowId { get; }

    /// <summary>Whether the buffer is allocated and ready.</summary>
    public bool IsAllocated => _bufferPointer != IntPtr.Zero;

    /// <summary>Current buffer size in bytes.</summary>
    public int BufferSize { get; private set; }

    /// <summary>Current slot size in bytes.</summary>
    public int SlotSize { get; private set; }

    /// <summary>Number of slots in this buffer.</summary>
    public int SlotCount => _config.SlotsPerWindow;

    /// <summary>Whether this buffer uses shared memory (vs local allocation).</summary>
    public bool UsesSharedMemory => _currentAllocation.IsValid;

    /// <summary>
    /// Gets the buffer offset within shared memory (only valid if UsesSharedMemory is true).
    /// </summary>
    public long SharedMemoryOffset => _currentAllocation.Offset;

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
        if (data.Length > SlotSize - FrameSlotHeader.Size)
        {
            _logger.Error($"Frame too large for slot: {data.Length} > {SlotSize - FrameSlotHeader.Size}");
            return -1;
        }

        var slotOffset = _writeIndex * SlotSize;

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

        _logger.Debug($"Window {WindowId}: Exact allocation for {rawFrameSize} bytes ({BufferSize / 1024} KB total)");
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

        _logger.Debug($"Window {WindowId}: Tranche {trancheIndex} allocation ({trancheSize / 1024} KB/slot, {BufferSize / 1024} KB total)");
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
        FreeCurrentBuffer();

        SlotSize = slotSize;
        BufferSize = slotSize * _config.SlotsPerWindow;

        // Try shared memory first, fall back to local allocation
        if (_sharedAllocator?.IsInitialized == true)
        {
            _currentAllocation = _sharedAllocator.Allocate(BufferSize);
            if (_currentAllocation.IsValid)
            {
                _bufferPointer = _currentAllocation.Pointer;
                _logger.Debug($"Window {WindowId}: Allocated {BufferSize} bytes from shared memory at offset {_currentAllocation.Offset}");
            }
            else
            {
                _logger.Warn($"Window {WindowId}: Shared memory allocation failed, falling back to local");
                AllocateLocal();
            }
        }
        else
        {
            AllocateLocal();
        }

        // Reset ring buffer indices
        _writeIndex = 0;
        _readIndex = 0;
    }

    private void AllocateLocal()
    {
        _bufferPointer = Marshal.AllocHGlobal(BufferSize);
        _currentAllocation = default; // Clear shared allocation

        // Zero the buffer
        unsafe
        {
            new Span<byte>((void*)_bufferPointer, BufferSize).Clear();
        }
    }

    private void FreeCurrentBuffer()
    {
        if (_bufferPointer == IntPtr.Zero)
        {
            return;
        }

        if (_currentAllocation.IsValid && _sharedAllocator != null)
        {
            // Free from shared memory
            _sharedAllocator.Free(_currentAllocation);
            _currentAllocation = default;
        }
        else
        {
            // Free local memory
            Marshal.FreeHGlobal(_bufferPointer);
        }

        _bufferPointer = IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        FreeCurrentBuffer();
    }
}

/// <summary>
/// Manages per-window frame buffers for all tracked windows.
/// </summary>
public sealed class PerWindowBufferManager : IDisposable
{
    private readonly IAgentLogger _logger;
    private PerWindowBufferConfig _config;
    private readonly SharedMemoryAllocator? _sharedAllocator;
    private readonly Dictionary<ulong, WindowFrameBuffer> _buffers = [];
    private readonly object _lock = new();
    private bool _disposed;

    public PerWindowBufferManager(
        PerWindowBufferConfig config,
        IAgentLogger logger,
        SharedMemoryAllocator? sharedAllocator = null)
    {
        _config = config;
        _logger = logger;
        _sharedAllocator = sharedAllocator;

        var allocMode = sharedAllocator?.IsInitialized == true ? "shared" : "local";
        _logger.Info($"PerWindowBufferManager created: mode={config.Mode}, slots={config.SlotsPerWindow}, allocation={allocMode}");
    }

    /// <summary>
    /// Gets the current frame buffer mode.
    /// </summary>
    public FrameBufferMode CurrentMode => _config.Mode;

    /// <summary>
    /// Updates the frame buffer mode for new buffer allocations.
    /// Existing buffers continue using their original mode until window resize.
    /// </summary>
    /// <param name="mode">The new buffer mode to use.</param>
    public void UpdateBufferMode(FrameBufferMode mode)
    {
        lock (_lock)
        {
            if (_config.Mode == mode) return;

            _config = _config with { Mode = mode };
            _logger.Info($"Buffer mode updated to: {mode}. New windows will use this mode.");
        }
    }

    /// <summary>
    /// Whether buffers will use shared memory.
    /// </summary>
    public bool UsesSharedMemory => _sharedAllocator?.IsInitialized == true;

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

            var buffer = new WindowFrameBuffer(windowId, _config, _logger, _sharedAllocator);
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
                _ = _buffers.Remove(windowId);
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
            var sharedCount = 0;

            foreach (var buffer in _buffers.Values)
            {
                if (buffer.IsAllocated)
                {
                    totalMemory += buffer.BufferSize;
                    allocatedCount++;
                    if (buffer.UsesSharedMemory)
                    {
                        sharedCount++;
                    }
                }
            }

            return new BufferManagerStats
            {
                WindowCount = _buffers.Count,
                AllocatedBufferCount = allocatedCount,
                SharedMemoryBufferCount = sharedCount,
                TotalMemoryBytes = totalMemory,
                Mode = _config.Mode,
                UsesSharedMemory = UsesSharedMemory
            };
        }
    }

    /// <summary>
    /// Gets shared memory statistics if available.
    /// </summary>
    public SharedMemoryStats? GetSharedMemoryStats() => _sharedAllocator?.GetStats();

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
                    _ = _buffers.Remove(id);
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
    public int SharedMemoryBufferCount { get; init; }
    public long TotalMemoryBytes { get; init; }
    public FrameBufferMode Mode { get; init; }
    public bool UsesSharedMemory { get; init; }

    public string TotalMemoryFormatted => TotalMemoryBytes switch
    {
        < 1024 => $"{TotalMemoryBytes} B",
        < 1024 * 1024 => $"{TotalMemoryBytes / 1024} KB",
        _ => $"{TotalMemoryBytes / (1024 * 1024)} MB"
    };

    public override string ToString()
    {
        var allocInfo = UsesSharedMemory
            ? $"Allocated={AllocatedBufferCount} (shared={SharedMemoryBufferCount})"
            : $"Allocated={AllocatedBufferCount}";
        return $"Mode={Mode}, Windows={WindowCount}, {allocInfo}, Memory={TotalMemoryFormatted}";
    }
}
