using System.IO.MemoryMappedFiles;

namespace WinRun.Agent.Services;

// ============================================================================
// Shared Memory Allocator for VirtioFS-backed Frame Buffers
//
// This allocator manages allocations within a memory-mapped file shared with
// the host via VirtioFS. Instead of using Marshal.AllocHGlobal, buffers are
// allocated from this shared region, allowing zero-copy frame transfer.
//
// The host creates the shared memory file via VZVirtioFileSystemDeviceConfiguration.
// The guest maps it and allocates per-window buffers from within.
// ============================================================================

/// <summary>
/// Configuration for the shared memory allocator.
/// </summary>
public sealed record SharedMemoryAllocatorConfig
{
    /// <summary>
    /// Path to the shared memory file.
    /// Default assumes VirtioFS mount at standard Windows location.
    /// </summary>
    public string SharedFilePath { get; init; } = @"\\.\winrun-framebuffer\framebuffer.shm";

    /// <summary>
    /// VirtioFS tag used by the host (for documentation/logging).
    /// </summary>
    public string VirtioFSTag { get; init; } = "winrun-framebuffer";

    /// <summary>
    /// Expected minimum size of the shared memory region in bytes.
    /// </summary>
    public long MinimumSizeBytes { get; init; } = 16 * 1024 * 1024; // 16 MB minimum

    /// <summary>
    /// Whether to create the file if it doesn't exist (for testing).
    /// In production, the host creates the file.
    /// </summary>
    public bool CreateIfNotExists { get; init; } = false;

    /// <summary>
    /// Size to create if file doesn't exist (only used with CreateIfNotExists).
    /// </summary>
    public long CreateSizeBytes { get; init; } = 256 * 1024 * 1024; // 256 MB
}

/// <summary>
/// Represents an allocation within the shared memory region.
/// </summary>
public readonly struct SharedAllocation
{
    /// <summary>Offset from the start of the shared region.</summary>
    public long Offset { get; init; }

    /// <summary>Size of the allocation in bytes.</summary>
    public int Size { get; init; }

    /// <summary>Pointer to the allocated memory (within the mapped region).</summary>
    public nint Pointer { get; init; }

    /// <summary>Whether this is a valid allocation.</summary>
    public bool IsValid => Pointer != IntPtr.Zero && Size > 0;
}

/// <summary>
/// Simple allocator for tracking used regions within shared memory.
/// Uses a first-fit free list approach.
/// </summary>
internal sealed class SharedMemoryFreeList
{
    private readonly List<(long Offset, int Size)> _freeBlocks = [];
    private readonly object _lock = new();

    public SharedMemoryFreeList(long totalSize)
    {
        // Start with one big free block (reserve header space)
        const int headerSize = 4096; // Reserve first 4KB for metadata
        _freeBlocks.Add((headerSize, (int)(totalSize - headerSize)));
    }

    /// <summary>
    /// Allocates a block of the specified size.
    /// Returns the offset, or -1 if no space available.
    /// </summary>
    public long Allocate(int size)
    {
        // Align to 64 bytes for cache efficiency
        var alignedSize = (size + 63) & ~63;

        lock (_lock)
        {
            for (var i = 0; i < _freeBlocks.Count; i++)
            {
                var (offset, blockSize) = _freeBlocks[i];
                if (blockSize >= alignedSize)
                {
                    _freeBlocks.RemoveAt(i);
                    if (blockSize > alignedSize)
                    {
                        // Put remainder back in free list
                        _freeBlocks.Add((offset + alignedSize, blockSize - alignedSize));
                    }
                    return offset;
                }
            }
        }

        return -1; // No space
    }

    /// <summary>
    /// Frees a previously allocated block.
    /// </summary>
    public void Free(long offset, int size)
    {
        var alignedSize = (size + 63) & ~63;

        lock (_lock)
        {
            _freeBlocks.Add((offset, alignedSize));
            // Could merge adjacent blocks here for better fragmentation handling
            // but keeping it simple for now
        }
    }

    /// <summary>
    /// Gets statistics about allocation.
    /// </summary>
    public (long TotalFree, int FreeBlockCount) GetStats()
    {
        lock (_lock)
        {
            long totalFree = 0;
            foreach (var (_, size) in _freeBlocks)
            {
                totalFree += size;
            }
            return (totalFree, _freeBlocks.Count);
        }
    }
}

/// <summary>
/// Manages allocations from a VirtioFS-shared memory region.
/// Thread-safe for concurrent allocation/deallocation.
/// </summary>
public sealed class SharedMemoryAllocator : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly SharedMemoryAllocatorConfig _config;
    private MemoryMappedFile? _mappedFile;
    private MemoryMappedViewAccessor? _accessor;
    private SharedMemoryFreeList? _freeList;
    private bool _disposed;
    private readonly object _initLock = new();

    public SharedMemoryAllocator(
        SharedMemoryAllocatorConfig config,
        IAgentLogger logger)
    {
        _config = config;
        _logger = logger;
    }

    /// <summary>
    /// Whether the allocator is initialized and ready.
    /// </summary>
    public bool IsInitialized => _mappedFile != null && BasePointer != IntPtr.Zero;

    /// <summary>
    /// Total size of the shared memory region.
    /// </summary>
    public long RegionSize { get; private set; }

    /// <summary>
    /// Base pointer to the mapped memory (for offset calculations).
    /// </summary>
    public nint BasePointer { get; private set; }

    /// <summary>
    /// Initializes the allocator by mapping the shared memory file.
    /// </summary>
    /// <returns>True if initialization succeeded, false otherwise.</returns>
    public bool Initialize()
    {
        lock (_initLock)
        {
            if (IsInitialized)
            {
                return true;
            }

            try
            {
                return InitializeInternal();
            }
            catch (Exception ex)
            {
                _logger.Error($"Failed to initialize shared memory allocator: {ex.Message}");
                return false;
            }
        }
    }

    private bool InitializeInternal()
    {
        var filePath = _config.SharedFilePath;

        // Check if file exists
        if (!File.Exists(filePath))
        {
            if (_config.CreateIfNotExists)
            {
                _logger.Info($"Creating shared memory file: {filePath}");
                try
                {
                    // Create directory if needed
                    var dir = Path.GetDirectoryName(filePath);
                    if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                    {
                        _ = Directory.CreateDirectory(dir);
                    }

                    // Create sparse file
                    using var fs = File.Create(filePath);
                    fs.SetLength(_config.CreateSizeBytes);
                }
                catch (Exception ex)
                {
                    _logger.Error($"Failed to create shared memory file: {ex.Message}");
                    return false;
                }
            }
            else
            {
                _logger.Warn($"Shared memory file not found: {filePath}");
                _logger.Info("Shared memory not available - falling back to local allocation");
                return false;
            }
        }

        // Get file size
        var fileInfo = new FileInfo(filePath);
        RegionSize = fileInfo.Length;

        if (RegionSize < _config.MinimumSizeBytes)
        {
            _logger.Error($"Shared memory file too small: {RegionSize} bytes (minimum: {_config.MinimumSizeBytes})");
            return false;
        }

        // Map the file
        try
        {
            _mappedFile = MemoryMappedFile.CreateFromFile(
                filePath,
                FileMode.Open,
                null,
                0,
                MemoryMappedFileAccess.ReadWrite);

            _accessor = _mappedFile.CreateViewAccessor(0, RegionSize, MemoryMappedFileAccess.ReadWrite);

            // Get the base pointer
            unsafe
            {
                byte* ptr = null;
                _accessor.SafeMemoryMappedViewHandle.AcquirePointer(ref ptr);
                BasePointer = (nint)ptr;
            }

            _freeList = new SharedMemoryFreeList(RegionSize);

            _logger.Info($"Shared memory allocator initialized: {RegionSize / (1024 * 1024)} MB at 0x{BasePointer:X}");
            return true;
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to map shared memory file: {ex.Message}");
            Cleanup();
            return false;
        }
    }

    /// <summary>
    /// Allocates a block from the shared memory region.
    /// </summary>
    /// <param name="size">Size in bytes to allocate.</param>
    /// <returns>The allocation, or an invalid allocation if failed.</returns>
    public SharedAllocation Allocate(int size)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (!IsInitialized || _freeList == null)
        {
            return default;
        }

        var offset = _freeList.Allocate(size);
        if (offset < 0)
        {
            _logger.Warn($"Shared memory allocation failed: no space for {size} bytes");
            return default;
        }

        var pointer = BasePointer + (nint)offset;

        // Zero the allocated memory
        unsafe
        {
            new Span<byte>((void*)pointer, size).Clear();
        }

        _logger.Debug($"Allocated {size} bytes at offset {offset} (0x{pointer:X})");

        return new SharedAllocation
        {
            Offset = offset,
            Size = size,
            Pointer = pointer
        };
    }

    /// <summary>
    /// Frees a previously allocated block.
    /// </summary>
    public void Free(SharedAllocation allocation)
    {
        if (_disposed || !IsInitialized || _freeList == null)
        {
            return;
        }

        if (!allocation.IsValid)
        {
            return;
        }

        _freeList.Free(allocation.Offset, allocation.Size);
        _logger.Debug($"Freed {allocation.Size} bytes at offset {allocation.Offset}");
    }

    /// <summary>
    /// Converts an offset to a pointer.
    /// </summary>
    public nint OffsetToPointer(long offset) =>
        !IsInitialized || offset < 0 || offset >= RegionSize
            ? IntPtr.Zero
            : BasePointer + (nint)offset;

    /// <summary>
    /// Converts a pointer to an offset.
    /// </summary>
    public long PointerToOffset(nint pointer)
    {
        if (!IsInitialized || pointer < BasePointer)
        {
            return -1;
        }

        var offset = pointer - BasePointer;
        return offset < RegionSize ? offset : -1;
    }

    /// <summary>
    /// Gets allocation statistics.
    /// </summary>
    public SharedMemoryStats GetStats()
    {
        if (_freeList == null)
        {
            return new SharedMemoryStats();
        }

        var (totalFree, freeBlockCount) = _freeList.GetStats();
        return new SharedMemoryStats
        {
            TotalSizeBytes = RegionSize,
            FreeBytes = totalFree,
            UsedBytes = RegionSize - totalFree,
            FreeBlockCount = freeBlockCount,
            IsInitialized = IsInitialized
        };
    }

    private void Cleanup()
    {
        if (_accessor != null)
        {
            if (BasePointer != IntPtr.Zero)
            {
                _accessor.SafeMemoryMappedViewHandle.ReleasePointer();
                BasePointer = IntPtr.Zero;
            }
            _accessor.Dispose();
            _accessor = null;
        }

        if (_mappedFile != null)
        {
            _mappedFile.Dispose();
            _mappedFile = null;
        }

        _freeList = null;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Cleanup();
    }
}

/// <summary>
/// Statistics about shared memory usage.
/// </summary>
public sealed record SharedMemoryStats
{
    public long TotalSizeBytes { get; init; }
    public long FreeBytes { get; init; }
    public long UsedBytes { get; init; }
    public int FreeBlockCount { get; init; }
    public bool IsInitialized { get; init; }

    public string TotalFormatted => FormatBytes(TotalSizeBytes);
    public string FreeFormatted => FormatBytes(FreeBytes);
    public string UsedFormatted => FormatBytes(UsedBytes);

    private static string FormatBytes(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => $"{bytes / 1024} KB",
        _ => $"{bytes / (1024 * 1024)} MB"
    };

    public override string ToString() =>
        IsInitialized
            ? $"Total={TotalFormatted}, Used={UsedFormatted}, Free={FreeFormatted}, Blocks={FreeBlockCount}"
            : "Not initialized";
}
