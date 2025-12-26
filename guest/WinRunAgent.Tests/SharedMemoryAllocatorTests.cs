using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class SharedMemoryAllocatorTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _tempFile;

    public SharedMemoryAllocatorTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"WinRunTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(_tempDir);
        _tempFile = Path.Combine(_tempDir, "test.shm");
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
        {
            try
            {
                Directory.Delete(_tempDir, true);
            }
            catch
            {
                // Ignore cleanup errors
            }
        }
    }

    [Fact]
    public void SharedMemoryAllocatorConfigHasReasonableDefaults()
    {
        var config = new SharedMemoryAllocatorConfig();

        Assert.Equal("winrun-framebuffer", config.VirtioFSTag);
        Assert.True(config.MinimumSizeBytes > 0);
        Assert.False(config.CreateIfNotExists);
    }

    [Fact]
    public void AllocatorStartsUninitialized()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig { SharedFilePath = _tempFile };

        using var allocator = new SharedMemoryAllocator(config, logger);

        Assert.False(allocator.IsInitialized);
        Assert.Equal(0, allocator.RegionSize);
        Assert.Equal(IntPtr.Zero, allocator.BasePointer);
    }

    [Fact]
    public void InitializeFailsIfFileDoesNotExist()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = false
        };

        using var allocator = new SharedMemoryAllocator(config, logger);

        var result = allocator.Initialize();

        Assert.False(result);
        Assert.False(allocator.IsInitialized);
    }

    [Fact]
    public void InitializeCreatesFileIfRequested()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 1024 * 1024 // 1 MB
        };

        using var allocator = new SharedMemoryAllocator(config, logger);

        var result = allocator.Initialize();

        Assert.True(result);
        Assert.True(allocator.IsInitialized);
        Assert.True(File.Exists(_tempFile));
        Assert.Equal(1024 * 1024, allocator.RegionSize);
    }

    [Fact]
    public void AllocateReturnsValidAllocation()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 1024 * 1024,
            MinimumSizeBytes = 1024
        };

        using var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();

        var allocation = allocator.Allocate(1024);

        Assert.True(allocation.IsValid);
        Assert.True(allocation.Offset > 0); // Header reserved
        Assert.Equal(1024, allocation.Size);
        Assert.NotEqual(IntPtr.Zero, allocation.Pointer);
    }

    [Fact]
    public void MultipleAllocationsReturnDifferentOffsets()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 1024 * 1024,
            MinimumSizeBytes = 1024
        };

        using var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();

        var alloc1 = allocator.Allocate(1024);
        var alloc2 = allocator.Allocate(1024);

        Assert.True(alloc1.IsValid);
        Assert.True(alloc2.IsValid);
        Assert.NotEqual(alloc1.Offset, alloc2.Offset);
        Assert.NotEqual(alloc1.Pointer, alloc2.Pointer);
    }

    [Fact]
    public void FreeReleasesAllocation()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 64 * 1024, // 64 KB - small to test running out
            MinimumSizeBytes = 1024
        };

        using var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();

        // Get initial free space
        var statsBefore = allocator.GetStats();

        // Allocate a chunk
        var allocation = allocator.Allocate(16 * 1024); // 16 KB
        Assert.True(allocation.IsValid);

        var statsAfterAlloc = allocator.GetStats();
        Assert.True(statsAfterAlloc.UsedBytes > statsBefore.UsedBytes);

        // Free it
        allocator.Free(allocation);

        var statsAfterFree = allocator.GetStats();
        Assert.True(statsAfterFree.FreeBytes >= statsAfterAlloc.FreeBytes);
    }

    [Fact]
    public void AllocateReturnsInvalidWhenOutOfSpace()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 32 * 1024, // 32 KB only
            MinimumSizeBytes = 1024
        };

        using var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();

        // Try to allocate more than available (accounting for header)
        var allocation = allocator.Allocate(64 * 1024); // 64 KB

        Assert.False(allocation.IsValid);
    }

    [Fact]
    public void OffsetToPointerConvertsCorrectly()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 1024 * 1024,
            MinimumSizeBytes = 1024
        };

        using var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();

        var allocation = allocator.Allocate(1024);
        var pointer = allocator.OffsetToPointer(allocation.Offset);

        Assert.Equal(allocation.Pointer, pointer);
    }

    [Fact]
    public void PointerToOffsetConvertsCorrectly()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 1024 * 1024,
            MinimumSizeBytes = 1024
        };

        using var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();

        var allocation = allocator.Allocate(1024);
        var offset = allocator.PointerToOffset(allocation.Pointer);

        Assert.Equal(allocation.Offset, offset);
    }

    [Fact]
    public void GetStatsReturnsCorrectInfo()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 1024 * 1024,
            MinimumSizeBytes = 1024
        };

        using var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();

        var stats = allocator.GetStats();

        Assert.True(stats.IsInitialized);
        Assert.Equal(1024 * 1024, stats.TotalSizeBytes);
        Assert.True(stats.FreeBytes > 0);
    }

    [Fact]
    public void SharedMemoryStatsFormatsCorrectly()
    {
        var stats = new SharedMemoryStats
        {
            TotalSizeBytes = 10 * 1024 * 1024,
            FreeBytes = 5 * 1024 * 1024,
            UsedBytes = 5 * 1024 * 1024,
            FreeBlockCount = 2,
            IsInitialized = true
        };

        Assert.Equal("10 MB", stats.TotalFormatted);
        Assert.Equal("5 MB", stats.FreeFormatted);
        Assert.Contains("10 MB", stats.ToString());
    }

    [Fact]
    public void SharedAllocationDefaultIsInvalid()
    {
        var allocation = new SharedAllocation();

        Assert.False(allocation.IsValid);
    }

    [Fact]
    public void AllocatorCanWriteAndReadData()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 1024 * 1024,
            MinimumSizeBytes = 1024
        };

        using var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();

        var allocation = allocator.Allocate(256);
        Assert.True(allocation.IsValid);

        // Write test data
        var testData = new byte[] { 0x12, 0x34, 0x56, 0x78 };
        unsafe
        {
            var ptr = (byte*)allocation.Pointer;
            for (var i = 0; i < testData.Length; i++)
            {
                ptr[i] = testData[i];
            }
        }

        // Read it back
        unsafe
        {
            var ptr = (byte*)allocation.Pointer;
            Assert.Equal(0x12, ptr[0]);
            Assert.Equal(0x34, ptr[1]);
            Assert.Equal(0x56, ptr[2]);
            Assert.Equal(0x78, ptr[3]);
        }
    }

    [Fact]
    public void DisposeReleasesResources()
    {
        var logger = new TestLogger();
        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 1024 * 1024,
            MinimumSizeBytes = 1024
        };

        var allocator = new SharedMemoryAllocator(config, logger);
        allocator.Initialize();
        Assert.True(allocator.IsInitialized);

        allocator.Dispose();

        // After dispose, trying to allocate should fail
        var allocation = allocator.Allocate(1024);
        Assert.False(allocation.IsValid);
    }
}

// Tests for WindowFrameBuffer with shared memory
public sealed class WindowFrameBufferSharedMemoryTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _tempFile;
    private readonly SharedMemoryAllocator _allocator;

    public WindowFrameBufferSharedMemoryTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"WinRunTests-{Guid.NewGuid()}");
        Directory.CreateDirectory(_tempDir);
        _tempFile = Path.Combine(_tempDir, "test.shm");

        var config = new SharedMemoryAllocatorConfig
        {
            SharedFilePath = _tempFile,
            CreateIfNotExists = true,
            CreateSizeBytes = 64 * 1024 * 1024, // 64 MB
            MinimumSizeBytes = 1024
        };

        _allocator = new SharedMemoryAllocator(config, new TestLogger());
        _allocator.Initialize();
    }

    public void Dispose()
    {
        _allocator.Dispose();

        if (Directory.Exists(_tempDir))
        {
            try
            {
                Directory.Delete(_tempDir, true);
            }
            catch
            {
                // Ignore cleanup errors
            }
        }
    }

    [Fact]
    public void WindowFrameBufferUsesSharedAllocatorWhenProvided()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var buffer = new WindowFrameBuffer(1, config, logger, _allocator);

        _ = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);

        Assert.True(buffer.IsAllocated);
        Assert.True(buffer.UsesSharedMemory);
        Assert.True(buffer.SharedMemoryOffset > 0);
    }

    [Fact]
    public void WindowFrameBufferUsesLocalAllocationWithoutSharedAllocator()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var buffer = new WindowFrameBuffer(1, config, logger, null);

        _ = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);

        Assert.True(buffer.IsAllocated);
        Assert.False(buffer.UsesSharedMemory);
    }

    [Fact]
    public void PerWindowBufferManagerReportsSharedMemoryUsage()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var manager = new PerWindowBufferManager(config, logger, _allocator);

        Assert.True(manager.UsesSharedMemory);

        var buffer = manager.GetOrCreateBuffer(1);
        _ = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);

        var stats = manager.GetStats();
        Assert.True(stats.UsesSharedMemory);
        Assert.Equal(1, stats.SharedMemoryBufferCount);
    }

    [Fact]
    public void PerWindowBufferManagerWithoutAllocatorDoesNotUseSharedMemory()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var manager = new PerWindowBufferManager(config, logger, null);

        Assert.False(manager.UsesSharedMemory);

        var stats = manager.GetStats();
        Assert.False(stats.UsesSharedMemory);
    }

    [Fact]
    public void BufferManagerStatsIncludesSharedMemoryInfo()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var manager = new PerWindowBufferManager(config, logger, _allocator);

        var buffer1 = manager.GetOrCreateBuffer(1);
        var buffer2 = manager.GetOrCreateBuffer(2);

        _ = buffer1.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);
        _ = buffer2.EnsureAllocated(1280, 720, 1280 * 720 * 4);

        var stats = manager.GetStats();

        Assert.Equal(2, stats.AllocatedBufferCount);
        Assert.Equal(2, stats.SharedMemoryBufferCount);
        Assert.True(stats.TotalMemoryBytes > 0);

        var sharedStats = manager.GetSharedMemoryStats();
        Assert.NotNull(sharedStats);
        Assert.True(sharedStats.Value.UsedBytes > 0);
    }

    [Fact]
    public void DisposingBufferFreesSharedMemory()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        var statsBefore = _allocator.GetStats();

        var buffer = new WindowFrameBuffer(1, config, logger, _allocator);
        _ = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);

        var statsAfterAlloc = _allocator.GetStats();
        Assert.True(statsAfterAlloc.UsedBytes > statsBefore.UsedBytes);

        buffer.Dispose();

        var statsAfterDispose = _allocator.GetStats();
        // Free bytes should increase after disposing
        Assert.True(statsAfterDispose.FreeBytes >= statsAfterAlloc.FreeBytes);
    }
}
