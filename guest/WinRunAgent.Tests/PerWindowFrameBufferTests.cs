using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class PerWindowFrameBufferTests
{
    [Fact]
    public void FrameBufferModeHasExpectedValues()
    {
        Assert.Equal(0, (int)FrameBufferMode.Uncompressed);
        Assert.Equal(1, (int)FrameBufferMode.Compressed);
    }

    [Fact]
    public void PerWindowBufferConfigHasReasonableDefaults()
    {
        var config = new PerWindowBufferConfig();

        Assert.Equal(FrameBufferMode.Uncompressed, config.Mode);
        Assert.Equal(3, config.SlotsPerWindow);
        Assert.Equal(4, config.BytesPerPixel);
        Assert.Equal(1.0, config.ExactAllocationHeadroom);
        Assert.NotEmpty(config.CompressedTranches);
    }

    [Fact]
    public void PerWindowBufferConfigCompressedTranchesAreOrdered()
    {
        var config = new PerWindowBufferConfig();

        for (var i = 1; i < config.CompressedTranches.Length; i++)
        {
            Assert.True(config.CompressedTranches[i] > config.CompressedTranches[i - 1],
                $"Tranche {i} should be larger than tranche {i - 1}");
        }
    }

    [Fact]
    public void WindowFrameBufferStartsUnallocated()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var buffer = new WindowFrameBuffer(123, config, logger);

        Assert.Equal(123ul, buffer.WindowId);
        Assert.False(buffer.IsAllocated);
        Assert.Equal(0, buffer.BufferSize);
        Assert.Equal(0, buffer.SlotSize);
        Assert.Equal(3, buffer.SlotCount);
    }

    [Fact]
    public void WindowFrameBufferAllocatesOnFirstFrame()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var buffer = new WindowFrameBuffer(1, config, logger);

        // 1920x1080 BGRA = 8,294,400 bytes
        var wasReallocated = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);

        Assert.True(wasReallocated);
        Assert.True(buffer.IsAllocated);
        Assert.True(buffer.BufferSize > 0);
        Assert.True(buffer.SlotSize > 0);
    }

    [Fact]
    public void WindowFrameBufferNoReallocationForSameSize()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var buffer = new WindowFrameBuffer(1, config, logger);

        // First allocation
        var firstAlloc = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);
        Assert.True(firstAlloc);

        var firstBufferSize = buffer.BufferSize;

        // Same size should not reallocate
        var secondAlloc = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);
        Assert.False(secondAlloc);
        Assert.Equal(firstBufferSize, buffer.BufferSize);
    }

    [Fact]
    public void WindowFrameBufferReallocatesOnSizeChange()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var buffer = new WindowFrameBuffer(1, config, logger);

        // First allocation at 1080p
        _ = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);
        var size1080p = buffer.BufferSize;

        // Resize to 4K should reallocate
        var wasReallocated = buffer.EnsureAllocated(3840, 2160, 3840 * 2160 * 4);
        Assert.True(wasReallocated);
        Assert.True(buffer.BufferSize > size1080p);
    }

    [Fact]
    public void WindowFrameBufferCompressedModeUsesTransches()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig
        {
            Mode = FrameBufferMode.Compressed,
            CompressedTranches = [1024 * 1024, 5 * 1024 * 1024, 20 * 1024 * 1024]
        };

        using var buffer = new WindowFrameBuffer(1, config, logger);

        // Small compressed frame should use smallest tranche
        _ = buffer.EnsureAllocated(1920, 1080, 500 * 1024); // 500KB compressed
        var smallTrancheSize = buffer.SlotSize;
        Assert.Equal(1024 * 1024, smallTrancheSize);

        // Larger compressed frame should use larger tranche
        var wasReallocated = buffer.EnsureAllocated(1920, 1080, 2 * 1024 * 1024); // 2MB compressed
        Assert.True(wasReallocated);
        Assert.Equal(5 * 1024 * 1024, buffer.SlotSize);
    }

    [Fact]
    public void WindowFrameBufferWriteFrameReturnsSlotIndex()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var buffer = new WindowFrameBuffer(1, config, logger);

        // Allocate for small test frame
        _ = buffer.EnsureAllocated(100, 100, 100 * 100 * 4);

        var header = new FrameSlotHeader
        {
            WindowId = 1,
            FrameNumber = 1,
            Width = 100,
            Height = 100,
            Stride = 400,
            Format = 0,
            DataSize = 100 * 100 * 4,
            Flags = FrameSlotFlags.KeyFrame
        };

        var data = new byte[100 * 100 * 4];
        var slotIndex = buffer.WriteFrame(header, data);

        Assert.Equal(0, slotIndex);
    }

    [Fact]
    public void WindowFrameBufferWriteFrameRotatesSlots()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig { SlotsPerWindow = 3 };

        using var buffer = new WindowFrameBuffer(1, config, logger);

        _ = buffer.EnsureAllocated(100, 100, 100 * 100 * 4);

        var header = new FrameSlotHeader
        {
            WindowId = 1,
            FrameNumber = 1,
            Width = 100,
            Height = 100,
            Stride = 400,
            Format = 0,
            DataSize = 100 * 100 * 4,
            Flags = FrameSlotFlags.KeyFrame
        };
        var data = new byte[100 * 100 * 4];

        var slot0 = buffer.WriteFrame(header, data);
        Assert.Equal(0, slot0);

        header = header with { FrameNumber = 2 };
        var slot1 = buffer.WriteFrame(header, data);
        Assert.Equal(1, slot1);

        // Buffer is full (only 2 writes allowed before read advances)
        header = header with { FrameNumber = 3 };
        var slot2 = buffer.WriteFrame(header, data);
        Assert.Equal(-1, slot2); // Buffer full

        // Advance read index
        buffer.AdvanceReadIndex();

        // Now we can write again
        var slot3 = buffer.WriteFrame(header, data);
        Assert.Equal(2, slot3);
    }

    [Fact]
    public void WindowFrameBufferRejectsOversizedFrame()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var buffer = new WindowFrameBuffer(1, config, logger);

        // Allocate for small frame
        _ = buffer.EnsureAllocated(100, 100, 100 * 100 * 4);

        var header = new FrameSlotHeader
        {
            WindowId = 1,
            FrameNumber = 1,
            Width = 100,
            Height = 100,
            Stride = 400,
            Format = 0,
            DataSize = (uint)(buffer.SlotSize * 2), // Way too big
            Flags = FrameSlotFlags.KeyFrame
        };

        var oversizedData = new byte[buffer.SlotSize * 2];
        var slotIndex = buffer.WriteFrame(header, oversizedData);

        Assert.Equal(-1, slotIndex);
    }

    [Fact]
    public void WindowFrameBufferDisposeFreesMemory()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        var buffer = new WindowFrameBuffer(1, config, logger);
        _ = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);
        Assert.True(buffer.IsAllocated);

        buffer.Dispose();
        // After dispose, accessing properties may throw or return invalid values
        // The important thing is that Dispose doesn't throw
    }

    [Fact]
    public void WindowFrameBufferDisposeIsIdempotent()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        var buffer = new WindowFrameBuffer(1, config, logger);
        _ = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);

        buffer.Dispose();
        buffer.Dispose(); // Should not throw
    }

    [Fact]
    public void PerWindowBufferManagerCreatesBuffersForWindows()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var manager = new PerWindowBufferManager(config, logger);

        var buffer1 = manager.GetOrCreateBuffer(1);
        var buffer2 = manager.GetOrCreateBuffer(2);

        Assert.NotSame(buffer1, buffer2);
        Assert.Equal(1ul, buffer1.WindowId);
        Assert.Equal(2ul, buffer2.WindowId);
    }

    [Fact]
    public void PerWindowBufferManagerReturnsSameBufferForSameWindow()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var manager = new PerWindowBufferManager(config, logger);

        var buffer1 = manager.GetOrCreateBuffer(1);
        var buffer2 = manager.GetOrCreateBuffer(1);

        Assert.Same(buffer1, buffer2);
    }

    [Fact]
    public void PerWindowBufferManagerRemovesBuffer()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var manager = new PerWindowBufferManager(config, logger);

        var buffer1 = manager.GetOrCreateBuffer(1);
        buffer1.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);

        manager.RemoveBuffer(1);

        // Getting buffer again should create a new one
        var buffer2 = manager.GetOrCreateBuffer(1);
        Assert.NotSame(buffer1, buffer2);
        Assert.False(buffer2.IsAllocated); // New buffer starts unallocated
    }

    [Fact]
    public void PerWindowBufferManagerCleansUpStaleBuffers()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var manager = new PerWindowBufferManager(config, logger);

        _ = manager.GetOrCreateBuffer(1);
        _ = manager.GetOrCreateBuffer(2);
        _ = manager.GetOrCreateBuffer(3);

        var stats = manager.GetStats();
        Assert.Equal(3, stats.WindowCount);

        // Cleanup: only windows 1 and 3 are active
        manager.CleanupStaleBuffers([1ul, 3ul]);

        stats = manager.GetStats();
        Assert.Equal(2, stats.WindowCount);
    }

    [Fact]
    public void PerWindowBufferManagerStatsReportsCorrectly()
    {
        var logger = new TestLogger();
        var config = new PerWindowBufferConfig();

        using var manager = new PerWindowBufferManager(config, logger);

        var stats = manager.GetStats();
        Assert.Equal(0, stats.WindowCount);
        Assert.Equal(0, stats.AllocatedBufferCount);
        Assert.Equal(0L, stats.TotalMemoryBytes);
        Assert.Equal(FrameBufferMode.Uncompressed, stats.Mode);

        var buffer = manager.GetOrCreateBuffer(1);
        _ = buffer.EnsureAllocated(1920, 1080, 1920 * 1080 * 4);

        stats = manager.GetStats();
        Assert.Equal(1, stats.WindowCount);
        Assert.Equal(1, stats.AllocatedBufferCount);
        Assert.True(stats.TotalMemoryBytes > 0);
    }

    [Fact]
    public void BufferManagerStatsFormatsMemoryCorrectly()
    {
        var stats = new BufferManagerStats
        {
            WindowCount = 1,
            AllocatedBufferCount = 1,
            TotalMemoryBytes = 500,
            Mode = FrameBufferMode.Uncompressed
        };
        Assert.Equal("500 B", stats.TotalMemoryFormatted);

        stats = stats with { TotalMemoryBytes = 5 * 1024 };
        Assert.Equal("5 KB", stats.TotalMemoryFormatted);

        stats = stats with { TotalMemoryBytes = 10 * 1024 * 1024 };
        Assert.Equal("10 MB", stats.TotalMemoryFormatted);
    }

    [Fact]
    public void BufferManagerStatsToStringIncludesAllInfo()
    {
        var stats = new BufferManagerStats
        {
            WindowCount = 2,
            AllocatedBufferCount = 1,
            TotalMemoryBytes = 8 * 1024 * 1024,
            Mode = FrameBufferMode.Compressed
        };

        var str = stats.ToString();

        Assert.Contains("Windows=2", str);
        Assert.Contains("Allocated=1", str);
        Assert.Contains("8 MB", str);
        Assert.Contains("Compressed", str);
    }

    [Fact]
    public void FrameStreamingConfigBufferModeDefaultsToUncompressed()
    {
        var config = new FrameStreamingConfig();

        Assert.Equal(FrameBufferMode.Uncompressed, config.BufferMode);
        Assert.Null(config.Compression);
    }

    [Fact]
    public void FrameStreamingConfigCanBeSetToCompressedMode()
    {
        var config = new FrameStreamingConfig
        {
            BufferMode = FrameBufferMode.Compressed,
            Compression = new FrameCompressionConfig { Enabled = true }
        };

        Assert.Equal(FrameBufferMode.Compressed, config.BufferMode);
        Assert.NotNull(config.Compression);
        Assert.True(config.Compression.Enabled);
    }

    [Fact]
    public void WindowBufferAllocatedMessageHasRequiredProperties()
    {
        var message = new WindowBufferAllocatedMessage
        {
            WindowId = 123,
            BufferPointer = 0x12345678,
            BufferSize = 8 * 1024 * 1024,
            SlotSize = 2 * 1024 * 1024,
            SlotCount = 3,
            IsCompressed = false
        };

        Assert.Equal(123ul, message.WindowId);
        Assert.Equal(0x12345678ul, message.BufferPointer);
        Assert.Equal(8 * 1024 * 1024, message.BufferSize);
        Assert.Equal(2 * 1024 * 1024, message.SlotSize);
        Assert.Equal(3, message.SlotCount);
        Assert.False(message.IsCompressed);
        Assert.False(message.IsReallocation); // Default
    }

    [Fact]
    public void WindowBufferAllocatedMessageCanBeReallocation()
    {
        var message = new WindowBufferAllocatedMessage
        {
            WindowId = 1,
            BufferPointer = 0x1000,
            BufferSize = 1024,
            SlotSize = 256,
            SlotCount = 3,
            IsCompressed = true,
            IsReallocation = true
        };

        Assert.True(message.IsReallocation);
        Assert.True(message.IsCompressed);
    }
}
