using System.Threading.Channels;
using WinRun.Agent.Services;

namespace WinRun.Agent;

public static class Program
{
    public static async Task Main(string[] _)
    {
        var cancellationSource = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellationSource.Cancel();
        };

        var logger = new ConsoleLogger();
        var windowTracker = new WindowTracker(logger);
        var launcher = new ProgramLauncher(logger);
        var iconService = new IconExtractionService(logger);
        var inputService = new InputInjectionService(logger);
        var clipboardService = new ClipboardSyncService(logger);
        var dragDropService = new DragDropService(logger);

        // Create channels for host<->agent communication
        var inboundChannel = Channel.CreateUnbounded<HostMessage>();
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        // Create shortcut service with callback to send notifications to host.
        var shortcutService = new ShortcutSyncService(
            logger,
            message => outboundChannel.Writer.WriteAsync(message).AsTask());

        // Set up frame streaming using shared memory + full-desktop fallback window (ID 0).
        // Full-desktop mode avoids black output when per-window IDs are not yet negotiated.
        FrameStreamingService? frameStreamingService = null;
        try
        {
            SharedMemoryAllocator? sharedAllocator = null;
            var allocator = new SharedMemoryAllocator(new SharedMemoryAllocatorConfig(), logger);
            if (allocator.Initialize())
            {
                sharedAllocator = allocator;
                logger.Info($"Shared memory allocator ready ({allocator.RegionSize / (1024 * 1024)} MB)");
            }
            else
            {
                logger.Warn("Shared memory allocator unavailable; frame streaming will use local buffers");
            }

            var frameConfig = new FrameStreamingConfig
            {
                EnablePerWindowCapture = false,
                BufferMode = FrameBufferMode.Uncompressed
            };

            frameStreamingService = new FrameStreamingService(
                logger,
                windowTracker,
                new DesktopDuplicationBridge(logger),
                outboundChannel,
                frameConfig,
                sharedAllocator);
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to initialize frame streaming dependencies: {ex.Message}");
        }

        // Set up Spice control port for host communication
        var controlPort = new SpiceControlPort(logger, inboundChannel, outboundChannel);
        var useControlPort = controlPort.TryOpen();

        if (useControlPort)
        {
            controlPort.Start();
            logger.Info("Connected to Spice control port");
        }
        else
        {
            logger.Warn("Spice control port not available - running in standalone mode");
        }

        var agent = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inputService,
            clipboardService,
            shortcutService,
            dragDropService,
            inboundChannel,
            outboundChannel,
            logger,
            frameStreamingService: frameStreamingService);

        try
        {
            await agent.RunAsync(cancellationSource.Token);
        }
        finally
        {
            if (useControlPort)
            {
                await controlPort.StopAsync();
                controlPort.Dispose();
            }
        }
    }
}
