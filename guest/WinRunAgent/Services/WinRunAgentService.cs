using System.Threading.Channels;

namespace WinRun.Agent.Services;

public sealed class WinRunAgentService
{
    private readonly WindowTracker _windowTracker;
    private readonly ProgramLauncher _launcher;
    private readonly IconExtractionService _iconService;
    private readonly Channel<HostMessage> _inboundChannel;
    private readonly IAgentLogger _logger;

    public WinRunAgentService(
        WindowTracker windowTracker,
        ProgramLauncher launcher,
        IconExtractionService iconService,
        Channel<HostMessage> inboundChannel,
        IAgentLogger logger)
    {
        _windowTracker = windowTracker;
        _launcher = launcher;
        _iconService = iconService;
        _inboundChannel = inboundChannel;
        _logger = logger;
    }

    public async Task RunAsync(CancellationToken token)
    {
        _logger.Info("WinRun guest agent starting up");
        _windowTracker.Start(OnWindowEvent);
        var reader = _inboundChannel.Reader;
        while (!token.IsCancellationRequested)
        {
            var message = await reader.ReadAsync(token);
            switch (message)
            {
                case LaunchProgramMessage launch:
                    await _launcher.LaunchAsync(launch.Path, launch.Arguments, token);
                    break;
                case RequestIconMessage iconRequest:
                    await _iconService.ExtractIconAsync(iconRequest.ExecutablePath, token);
                    break;
                case ShortcutCreatedMessage shortcut:
                    _logger.Info($"Shortcut created: {shortcut.ShortcutPath} -> {shortcut.TargetPath}");
                    break;
                default:
                    _logger.Warn($"Unhandled message type {message.GetType().Name}");
                    break;
            }
        }
    }

    private void OnWindowEvent(object? sender, WindowEventArgs e)
    {
        _logger.Debug($"Window {e.WindowId} updated title {e.Title} bounds {e.Bounds}");
    }
}
