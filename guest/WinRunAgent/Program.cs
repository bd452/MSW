using System.Threading.Channels;
using WinRun.Agent.Services;

namespace WinRun.Agent;

public static class Program
{
    public static async Task Main(string[] _args)
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
        var desktopDuplication = new DesktopDuplicationBridge(logger);
        SharedMemoryAllocator? sharedMemoryAllocator = null;
        FrameStreamingService? frameStreamingService = null;

        // Create channels for host<->agent communication
        var inboundChannel = Channel.CreateUnbounded<HostMessage>();
        var outboundChannel = Channel.CreateUnbounded<GuestMessage>();

        // Set up Spice control port for host communication
        var controlPort = new SpiceControlPort(logger, inboundChannel, outboundChannel);
        var useControlPort = controlPort.TryOpen();

        if (useControlPort)
        {
            controlPort.Start();
            logger.Info("Connected to Spice control port");

            // Initialize shared memory allocator for zero-copy frame transport.
            var allocator = new SharedMemoryAllocator(
                new SharedMemoryAllocatorConfig
                {
                    // Host usually creates this file, but allow guest creation as fallback.
                    CreateIfNotExists = true
                },
                logger);

            if (allocator.Initialize())
            {
                sharedMemoryAllocator = allocator;
                logger.Info("Shared memory allocator ready for frame streaming");
            }
            else
            {
                allocator.Dispose();
                logger.Warn("Shared memory allocator unavailable; frame buffers will use local allocations");
            }

            frameStreamingService = new FrameStreamingService(
                logger,
                windowTracker,
                desktopDuplication,
                outboundChannel,
                config: new FrameStreamingConfig(),
                sharedMemoryAllocator: sharedMemoryAllocator
            );
        }
        else
        {
            logger.Warn("Spice control port not available - running in standalone mode");
        }

        var shortcutService = new ShortcutSyncService(
            logger,
            msg =>
            {
                outboundChannel.Writer.TryWrite(msg);
            });

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
            telemetry: null,
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

            agent.Dispose();
            sharedMemoryAllocator?.Dispose();
            desktopDuplication.Dispose();
        }
    }
}
