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

        var agent = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            Channel.CreateUnbounded<HostMessage>(),
            logger);

        await agent.RunAsync(cancellationSource.Token);
    }
}
