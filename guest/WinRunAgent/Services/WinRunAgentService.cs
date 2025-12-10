using System.Threading.Channels;

namespace WinRun.Agent.Services;

/// <summary>
/// Main guest agent service coordinating window tracking, program launching,
/// session management, and host communication.
/// </summary>
public sealed class WinRunAgentService : IDisposable
{
    private readonly WindowTracker _windowTracker;
    private readonly ProgramLauncher _launcher;
    private readonly IconExtractionService _iconService;
    private readonly SessionManager _sessionManager;
    private readonly Channel<HostMessage> _inboundChannel;
    private readonly Channel<GuestMessage> _outboundChannel;
    private readonly IAgentLogger _logger;
    private bool _disposed;

    public WinRunAgentService(
        WindowTracker windowTracker,
        ProgramLauncher launcher,
        IconExtractionService iconService,
        Channel<HostMessage> inboundChannel,
        Channel<GuestMessage> outboundChannel,
        IAgentLogger logger)
    {
        _windowTracker = windowTracker;
        _launcher = launcher;
        _iconService = iconService;
        _inboundChannel = inboundChannel;
        _outboundChannel = outboundChannel;
        _logger = logger;

        _sessionManager = new SessionManager(
            logger,
            launcher,
            windowTracker,
            SendMessageAsync);

        // Subscribe to session state changes
        _sessionManager.SessionStateChanged += OnSessionStateChanged;
    }

    /// <summary>
    /// Backward compatibility constructor without outbound channel.
    /// </summary>
    public WinRunAgentService(
        WindowTracker windowTracker,
        ProgramLauncher launcher,
        IconExtractionService iconService,
        Channel<HostMessage> inboundChannel,
        IAgentLogger logger)
        : this(windowTracker, launcher, iconService, inboundChannel,
               Channel.CreateUnbounded<GuestMessage>(), logger)
    {
    }

    /// <summary>
    /// Gets the session manager for external access.
    /// </summary>
    public SessionManager SessionManager => _sessionManager;

    /// <summary>
    /// Runs the agent service, processing messages until cancelled.
    /// </summary>
    public async Task RunAsync(CancellationToken token)
    {
        _logger.Info("WinRun guest agent starting up");

        // Start window tracking
        _windowTracker.Start(OnWindowEvent);

        // Start session management (heartbeats, idle detection)
        _sessionManager.Start();

        try
        {
            // Send initial capability announcement
            await SendCapabilityAnnouncementAsync();

            // Process incoming messages
            await ProcessMessagesAsync(token);
        }
        finally
        {
            _sessionManager.Stop();
            _windowTracker.Stop();
            _logger.Info("WinRun guest agent shut down");
        }
    }

    private async Task ProcessMessagesAsync(CancellationToken token)
    {
        var reader = _inboundChannel.Reader;

        while (!token.IsCancellationRequested)
        {
            try
            {
                var message = await reader.ReadAsync(token);
                await HandleMessageAsync(message, token);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.Error($"Error processing message: {ex.Message}");
            }
        }
    }

    private async Task HandleMessageAsync(HostMessage message, CancellationToken token)
    {
        switch (message)
        {
            case LaunchProgramMessage launch:
                await HandleLaunchProgramAsync(launch, token);
                break;

            case RequestIconMessage iconRequest:
                await HandleIconRequestAsync(iconRequest, token);
                break;

            case ShutdownMessage shutdown:
                await HandleShutdownAsync(shutdown, token);
                break;

            case MouseInputMessage mouseInput:
                HandleMouseInput(mouseInput);
                break;

            case KeyboardInputMessage keyboardInput:
                HandleKeyboardInput(keyboardInput);
                break;

            case HostClipboardMessage clipboardData:
                HandleClipboardData(clipboardData);
                break;

            case DragDropMessage dragDrop:
                HandleDragDrop(dragDrop);
                break;

            default:
                _logger.Warn($"Unhandled message type {message.GetType().Name}");
                await SendAckAsync(message.MessageId, success: false, "Unknown message type");
                break;
        }
    }

    private async Task HandleLaunchProgramAsync(LaunchProgramMessage launch, CancellationToken token)
    {
        _logger.Info($"Launching program: {launch.Path}");

        var result = await _launcher.LaunchAsync(launch, token);

        if (result.Success)
        {
            _logger.Info($"Program launched successfully: PID {result.ProcessId}");

            // Track the session
            if (result.ProcessId.HasValue)
            {
                _sessionManager.TrackSession(result.ProcessId.Value, launch.Path);
            }

            await SendAckAsync(launch.MessageId, success: true);
        }
        else
        {
            _logger.Error($"Failed to launch {launch.Path}: {result.ErrorMessage}");
            await SendAckAsync(launch.MessageId, success: false, result.ErrorMessage);
        }
    }

    private async Task HandleIconRequestAsync(RequestIconMessage iconRequest, CancellationToken token)
    {
        _logger.Debug($"Icon request for: {iconRequest.ExecutablePath}");

        var iconBytes = await _iconService.ExtractIconAsync(iconRequest.ExecutablePath, token);

        if (iconBytes.Length > 0)
        {
            // Create IconDataMessage from extracted bytes
            // For now, assume it's a 256x256 PNG (the service will provide real dimensions)
            var iconMessage = new IconDataMessage
            {
                ExecutablePath = iconRequest.ExecutablePath,
                Width = iconRequest.PreferredSize,
                Height = iconRequest.PreferredSize,
                PngData = iconBytes
            };
            await SendMessageAsync(iconMessage);
            await SendAckAsync(iconRequest.MessageId, success: true);
        }
        else
        {
            await SendAckAsync(iconRequest.MessageId, success: false, "Failed to extract icon");
        }
    }

    private async Task HandleShutdownAsync(ShutdownMessage shutdown, CancellationToken token)
    {
        _logger.Info($"Shutdown requested with timeout {shutdown.TimeoutMs}ms");

        // Gracefully stop all sessions
        foreach (var session in _sessionManager.GetActiveSessions())
        {
            _sessionManager.MarkSessionExited(session.ProcessId);
        }

        await SendAckAsync(shutdown.MessageId, success: true);
    }

    private void HandleMouseInput(MouseInputMessage mouseInput)
    {
        // Record activity for the target window's session
        var session = _sessionManager.GetSessionForWindow(mouseInput.WindowId);
        if (session != null)
        {
            _sessionManager.RecordActivity(session.ProcessId);
        }

        // TODO: Inject mouse input to Windows (SendInput)
        _logger.Debug($"Mouse {mouseInput.EventType} at ({mouseInput.X}, {mouseInput.Y}) for window {mouseInput.WindowId}");
    }

    private void HandleKeyboardInput(KeyboardInputMessage keyboardInput)
    {
        // Record activity for the target window's session
        var session = _sessionManager.GetSessionForWindow(keyboardInput.WindowId);
        if (session != null)
        {
            _sessionManager.RecordActivity(session.ProcessId);
        }

        // TODO: Inject keyboard input to Windows (SendInput)
        _logger.Debug($"Keyboard {keyboardInput.EventType} key {keyboardInput.KeyCode} for window {keyboardInput.WindowId}");
    }

    private void HandleClipboardData(HostClipboardMessage clipboardData)
    {
        // TODO: Set Windows clipboard
        _logger.Debug($"Clipboard data received: {clipboardData.Format}, {clipboardData.Data.Length} bytes");
    }

    private void HandleDragDrop(DragDropMessage dragDrop)
    {
        // Record activity
        var session = _sessionManager.GetSessionForWindow(dragDrop.WindowId);
        if (session != null)
        {
            _sessionManager.RecordActivity(session.ProcessId);
        }

        // TODO: Handle drag/drop operations
        _logger.Debug($"DragDrop {dragDrop.EventType} for window {dragDrop.WindowId}");
    }

    private async Task SendCapabilityAnnouncementAsync()
    {
        var capabilities =
            GuestCapabilities.WindowTracking |
            GuestCapabilities.IconExtraction |
            GuestCapabilities.ClipboardSync |
            GuestCapabilities.HighDpiSupport;

        var message = SpiceMessageSerializer.CreateCapabilityMessage(capabilities);
        await SendMessageAsync(message);

        _logger.Info($"Sent capability announcement: {capabilities}");
    }

    private async Task SendAckAsync(uint messageId, bool success, string? errorMessage = null)
    {
        var ack = new AckMessage
        {
            MessageId = messageId,
            Success = success,
            ErrorMessage = errorMessage
        };

        await SendMessageAsync(ack);
    }

    private async Task SendMessageAsync(GuestMessage message)
    {
        try
        {
            await _outboundChannel.Writer.WriteAsync(message);
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to send message: {ex.Message}");
        }
    }

    private void OnWindowEvent(object? sender, WindowEventArgs e)
    {
        _logger.Debug($"Window {e.WindowId} {e.EventType}: \"{e.Title}\" {e.Bounds}");

        // Send window metadata to host
        var metadata = SpiceMessageSerializer.CreateWindowMetadata(e);
        _ = SendMessageAsync(metadata);
    }

    private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs e)
    {
        _logger.Info($"Session {e.Session.ProcessId} state: {e.PreviousState} -> {e.NewState}");
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _sessionManager.Dispose();
        _launcher.Dispose();
        _windowTracker.Dispose();
        _disposed = true;
    }
}
