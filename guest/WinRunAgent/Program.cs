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
        }
        else
        {
            logger.Warn("Spice control port not available - running in standalone mode");
        }

        var agent = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inboundChannel,
            outboundChannel,
            logger);

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
