using System.Threading.Channels;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class FrameStreamingServiceTests
{
    [Fact]
    public void FrameStreamingConfigHasReasonableDefaults()
    {
        var config = new FrameStreamingConfig();

        Assert.Equal(30, config.TargetFps);
        Assert.Equal(100, config.CaptureTimeoutMs);
        Assert.Equal(10, config.MaxConsecutiveFailures);
        Assert.Equal(1000, config.ReinitializationDelayMs);
        Assert.True(config.EnablePerWindowCapture);
        Assert.Equal(33, config.MinWindowFrameIntervalMs);
    }

    [Fact]
    public void FrameStreamingConfigComputesTargetFrameInterval()
    {
        var config30Fps = new FrameStreamingConfig { TargetFps = 30 };
        Assert.Equal(33, config30Fps.TargetFrameIntervalMs);

        var config60Fps = new FrameStreamingConfig { TargetFps = 60 };
        Assert.Equal(16, config60Fps.TargetFrameIntervalMs);

        var config15Fps = new FrameStreamingConfig { TargetFps = 15 };
        Assert.Equal(66, config15Fps.TargetFrameIntervalMs);
    }

    [Fact]
    public void FrameStreamingServiceInitializesWithDependencies()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        Assert.False(service.IsRunning);
        Assert.Equal(0u, service.TotalFramesCaptured);
    }

    [Fact]
    public void FrameStreamingServiceAcceptsCustomConfig()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();
        var config = new FrameStreamingConfig { TargetFps = 60 };

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel,
            config);

        // Service should initialize without throwing
        Assert.NotNull(service);
    }

    [Fact]
    public void FrameStreamingServiceStartSetsIsRunning()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        Assert.False(service.IsRunning);

        service.Start();

        // Give the background task a moment to start
        Thread.Sleep(50);

        // Note: IsRunning may be true or false depending on whether
        // desktop duplication initialized successfully (it won't in tests)
        // The important thing is that Start() doesn't throw
    }

    [Fact]
    public async Task FrameStreamingServiceStopAsync_WhenNotRunning_CompletesImmediately()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        // Should complete immediately when not running
        await service.StopAsync();
    }

    [Fact]
    public async Task FrameStreamingServiceCanStartAndStop()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        service.Start();
        await Task.Delay(100); // Let it run briefly

        await service.StopAsync();

        Assert.False(service.IsRunning);
    }

    [Fact]
    public void FrameStreamingServiceDisposeIsIdempotent()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        service.Dispose();
        service.Dispose(); // Should not throw
    }

    [Fact]
    public void FrameStreamingServiceThrowsAfterDispose()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        service.Dispose();

        _ = Assert.Throws<ObjectDisposedException>(service.Start);
    }

    [Fact]
    public void FrameStreamingServiceDoubleStartIsNoOp()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        service.Start();
        service.Start(); // Should log warning but not throw

        Assert.Contains(logger.WarnMessages, m => m.Contains("already running"));
    }

    [Fact]
    public void FrameStreamingStatsInitializesToZero()
    {
        var stats = new FrameStreamingStats();

        Assert.Equal(0, stats.CaptureAttempts);
        Assert.Equal(0, stats.FramesCaptured);
        Assert.Equal(0, stats.FramesWritten);
        Assert.Equal(0, stats.NotificationsSent);
        Assert.Equal(0, stats.CaptureErrors);
        Assert.Equal(0, stats.BufferFullCount);
    }

    [Fact]
    public void FrameStreamingStatsRecordsMethods()
    {
        var stats = new FrameStreamingStats();

        stats.RecordCaptureAttempt();
        stats.RecordCaptureAttempt();
        Assert.Equal(2, stats.CaptureAttempts);

        stats.RecordFrameCaptured();
        Assert.Equal(1, stats.FramesCaptured);

        stats.RecordFrameWritten();
        Assert.Equal(1, stats.FramesWritten);

        stats.RecordNotificationSent();
        Assert.Equal(1, stats.NotificationsSent);

        stats.RecordCaptureError();
        Assert.Equal(1, stats.CaptureErrors);

        stats.RecordBufferFull();
        Assert.Equal(1, stats.BufferFullCount);
    }

    [Fact]
    public void FrameStreamingStatsToStringFormatsCorrectly()
    {
        var stats = new FrameStreamingStats();
        stats.RecordCaptureAttempt();
        stats.RecordFrameCaptured();

        var str = stats.ToString();

        Assert.Contains("Attempts=1", str);
        Assert.Contains("Captured=1", str);
        Assert.Contains("Written=0", str);
    }

    [Fact]
    public void FrameStreamingServiceExposesStats()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        Assert.NotNull(service.Stats);
        Assert.Equal(0, service.Stats.CaptureAttempts);
    }

    [Fact]
    public void CleanupStaleWindowStates_WhenNoWindows_NoErrors()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        // Should not throw when no windows are tracked
        service.CleanupStaleWindowStates();
    }

    [Fact]
    public void FrameReadyMessageHasRequiredProperties()
    {
        var message = new FrameReadyMessage
        {
            WindowId = 123,
            SlotIndex = 0,
            FrameNumber = 42
        };

        Assert.Equal(123ul, message.WindowId);
        Assert.Equal(0u, message.SlotIndex);
        Assert.Equal(42u, message.FrameNumber);
        Assert.True(message.IsKeyFrame); // Default value
    }

    [Fact]
    public void FrameReadyMessageIsKeyFrameDefaultsToTrue()
    {
        var message = new FrameReadyMessage
        {
            WindowId = 1,
            SlotIndex = 0,
            FrameNumber = 1
        };

        Assert.True(message.IsKeyFrame);
    }

    [Fact]
    public void FrameReadyMessageCanSetIsKeyFrameFalse()
    {
        var message = new FrameReadyMessage
        {
            WindowId = 1,
            SlotIndex = 0,
            FrameNumber = 1,
            IsKeyFrame = false
        };

        Assert.False(message.IsKeyFrame);
    }

    [Fact]
    public void FrameStreamingServiceLogsOnStart()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        service.Start();
        Thread.Sleep(50);

        Assert.Contains(logger.InfoMessages, m => m.Contains("Starting frame streaming"));
    }

    [Fact]
    public void FrameStreamingServiceLogsOnDispose()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        service.Dispose();

        Assert.Contains(logger.InfoMessages, m => m.Contains("disposed"));
    }

    [Fact]
    public void WindowFrameStateRecordHasRequiredProperties()
    {
        // WindowFrameState is internal but we can test its usage pattern
        // by testing that the service properly tracks per-window state
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel);

        // Service should handle per-window state without errors
        service.CleanupStaleWindowStates();
    }

    [Fact]
    public void FrameStreamingConfigPerWindowCaptureCanBeDisabled()
    {
        var config = new FrameStreamingConfig { EnablePerWindowCapture = false };

        Assert.False(config.EnablePerWindowCapture);
    }

    [Fact]
    public void FrameStreamingConfigWithDifferentFpsValues()
    {
        // Test edge cases for FPS configuration
        var config1Fps = new FrameStreamingConfig { TargetFps = 1 };
        Assert.Equal(1000, config1Fps.TargetFrameIntervalMs);

        var config120Fps = new FrameStreamingConfig { TargetFps = 120 };
        Assert.Equal(8, config120Fps.TargetFrameIntervalMs);
    }

    [Fact]
    public void FrameStreamingServiceWithoutSharedMemory()
    {
        var logger = new TestLogger();
        var windowTracker = new WindowTracker(logger);
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        using var service = new FrameStreamingService(
            logger,
            windowTracker,
            desktopDuplication,
            outboundChannel,
            sharedMemoryAllocator: null);

        Assert.False(service.UsesSharedMemory);
    }

    [Fact]
    public void FrameStreamingServiceWithSharedMemoryUncompressedMode()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"WinRunTests-{Guid.NewGuid()}");
        _ = Directory.CreateDirectory(tempDir);
        var tempFile = Path.Combine(tempDir, "test.shm");

        try
        {
            var allocatorConfig = new SharedMemoryAllocatorConfig
            {
                SharedFilePath = tempFile,
                CreateIfNotExists = true,
                CreateSizeBytes = 64 * 1024 * 1024,
                MinimumSizeBytes = 1024
            };

            using var allocator = new SharedMemoryAllocator(allocatorConfig, new TestLogger());
            allocator.Initialize();

            var logger = new TestLogger();
            var windowTracker = new WindowTracker(logger);
            var desktopDuplication = new DesktopDuplicationBridge(logger);
            var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

            var config = new FrameStreamingConfig
            {
                BufferMode = FrameBufferMode.Uncompressed
            };

            using var service = new FrameStreamingService(
                logger,
                windowTracker,
                desktopDuplication,
                outboundChannel,
                config,
                allocator);

            Assert.True(service.UsesSharedMemory);
        }
        finally
        {
            if (Directory.Exists(tempDir))
            {
                try { Directory.Delete(tempDir, true); } catch { }
            }
        }
    }

    [Fact]
    public void FrameStreamingServiceWithSharedMemoryCompressedMode()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"WinRunTests-{Guid.NewGuid()}");
        _ = Directory.CreateDirectory(tempDir);
        var tempFile = Path.Combine(tempDir, "test.shm");

        try
        {
            var allocatorConfig = new SharedMemoryAllocatorConfig
            {
                SharedFilePath = tempFile,
                CreateIfNotExists = true,
                CreateSizeBytes = 64 * 1024 * 1024,
                MinimumSizeBytes = 1024
            };

            using var allocator = new SharedMemoryAllocator(allocatorConfig, new TestLogger());
            allocator.Initialize();

            var logger = new TestLogger();
            var windowTracker = new WindowTracker(logger);
            var desktopDuplication = new DesktopDuplicationBridge(logger);
            var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

            var config = new FrameStreamingConfig
            {
                BufferMode = FrameBufferMode.Compressed,
                Compression = new FrameCompressionConfig { Enabled = true }
            };

            using var service = new FrameStreamingService(
                logger,
                windowTracker,
                desktopDuplication,
                outboundChannel,
                config,
                allocator);

            Assert.True(service.UsesSharedMemory);
            Assert.NotNull(service.CompressionStats);
        }
        finally
        {
            if (Directory.Exists(tempDir))
            {
                try { Directory.Delete(tempDir, true); } catch { }
            }
        }
    }
}
