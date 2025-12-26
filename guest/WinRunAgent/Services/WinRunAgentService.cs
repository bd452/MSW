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
    private readonly InputInjectionService _inputService;
    private readonly ClipboardSyncService _clipboardService;
    private readonly DragDropService _dragDropService;
    private readonly Channel<HostMessage> _inboundChannel;
    private readonly Channel<GuestMessage> _outboundChannel;
    private readonly IAgentLogger _logger;
    private bool _disposed;

    public WinRunAgentService(
        WindowTracker windowTracker,
        ProgramLauncher launcher,
        IconExtractionService iconService,
        InputInjectionService inputService,
        ClipboardSyncService clipboardService,
        ShortcutSyncService shortcutService,
        DragDropService dragDropService,
        Channel<HostMessage> inboundChannel,
        Channel<GuestMessage> outboundChannel,
        IAgentLogger logger,
        SpiceChannelTelemetry? telemetry = null,
        FrameStreamingService? frameStreamingService = null)
    {
        _windowTracker = windowTracker;
        _launcher = launcher;
        _iconService = iconService;
        _inputService = inputService;
        _clipboardService = clipboardService;
        _dragDropService = dragDropService;
        FrameStreaming = frameStreamingService;
        ShortcutService = shortcutService;
        _inboundChannel = inboundChannel;
        _outboundChannel = outboundChannel;
        _logger = logger;
        Telemetry = telemetry ?? new SpiceChannelTelemetry(logger, outboundChannel);

        SessionManager = new SessionManager(
            logger,
            launcher,
            windowTracker,
            SendMessageAsync);

        // Subscribe to session state changes
        SessionManager.SessionStateChanged += OnSessionStateChanged;

        // Subscribe to clipboard changes
        _clipboardService.ClipboardChanged += OnClipboardChanged;
    }

    /// <summary>
    /// Simplified constructor with separate inbound/outbound channels.
    /// </summary>
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
        _inputService = new InputInjectionService(logger);
        _clipboardService = new ClipboardSyncService(logger);
        _dragDropService = new DragDropService(logger);
        _inboundChannel = inboundChannel;
        _outboundChannel = outboundChannel;
        _logger = logger;
        Telemetry = new SpiceChannelTelemetry(logger, _outboundChannel);

        // Create shortcut service with callback to send messages
        ShortcutService = new ShortcutSyncService(
            logger,
            msg => _ = SendMessageAsync(msg));

        SessionManager = new SessionManager(
            logger,
            launcher,
            windowTracker,
            SendMessageAsync);

        // Subscribe to session state changes
        SessionManager.SessionStateChanged += OnSessionStateChanged;

        // Subscribe to clipboard changes
        _clipboardService.ClipboardChanged += OnClipboardChanged;
    }

    /// <summary>
    /// Backward compatibility constructor without outbound channel.
    /// Creates internal outbound channel that is not connected to any transport.
    /// </summary>
    public WinRunAgentService(
        WindowTracker windowTracker,
        ProgramLauncher launcher,
        IconExtractionService iconService,
        Channel<HostMessage> inboundChannel,
        IAgentLogger logger)
        : this(windowTracker, launcher, iconService, inboundChannel, Channel.CreateUnbounded<GuestMessage>(), logger)
    {
    }

    /// <summary>
    /// Gets the session manager for external access.
    /// </summary>
    public SessionManager SessionManager { get; }

    /// <summary>
    /// Gets the shortcut sync service for external access (e.g., manual rescan).
    /// </summary>
    public ShortcutSyncService ShortcutService { get; }

    /// <summary>
    /// Gets the channel telemetry for metrics and diagnostics.
    /// </summary>
    public SpiceChannelTelemetry Telemetry { get; }

    /// <summary>
    /// Gets the frame streaming service (null if not configured).
    /// </summary>
    public FrameStreamingService? FrameStreaming { get; }

    /// <summary>
    /// Runs the agent service, processing messages until cancelled.
    /// </summary>
    public async Task RunAsync(CancellationToken token)
    {
        _logger.Info("WinRun guest agent starting up");

        // Send initial capability announcement first, before any other messages
        await SendCapabilityAnnouncementAsync();

        // Start window tracking
        _windowTracker.Start(OnWindowEvent);

        // Start session management (heartbeats, idle detection)
        SessionManager.Start();

        // Start shortcut monitoring
        ShortcutService.Start();

        // Start frame streaming if configured
        FrameStreaming?.Start();

        try
        {
            // Process incoming messages
            await ProcessMessagesAsync(token);
        }
        finally
        {
            // Stop frame streaming
            if (FrameStreaming != null)
            {
                await FrameStreaming.StopAsync();
                _logger.Info($"Frame streaming stopped. Stats: {FrameStreaming.Stats}");
            }

            ShortcutService.Stop();
            SessionManager.Stop();
            _windowTracker.Stop();

            // Send final telemetry report
            try
            {
                await Telemetry.ReportTelemetryAsync();
            }
            catch
            {
                // Ignore telemetry errors during shutdown
            }

            // Log final telemetry stats
            _logger.Info("WinRun guest agent shut down", Telemetry.GetTelemetryMetadata());
        }
    }

    private async Task ProcessMessagesAsync(CancellationToken token)
    {
        var reader = _inboundChannel.Reader;

        while (!token.IsCancellationRequested)
        {
            try
            {
                Telemetry.Metrics.RecordReceiveAttempt();
                var message = await reader.ReadAsync(token);
                Telemetry.RecordReceiveSuccess();

                try
                {
                    await HandleMessageAsync(message, token);
                }
                catch (Exception ex)
                {
                    Telemetry.RecordMessageProcessingError(ex.Message);
                    _logger.Error($"Error handling message {message.GetType().Name}: {ex.Message}");
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                break;
            }
            catch (ChannelClosedException ex)
            {
                Telemetry.RecordReceiveFailure($"Channel closed: {ex.Message}");
                _logger.Error($"Inbound channel closed: {ex.Message}");
                break;
            }
            catch (Exception ex)
            {
                Telemetry.RecordReceiveFailure(ex.Message);
                _logger.Error($"Error receiving message: {ex.Message}");
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

            case ListSessionsMessage listSessions:
                await HandleListSessionsAsync(listSessions);
                break;

            case CloseSessionMessage closeSession:
                await HandleCloseSessionAsync(closeSession);
                break;

            case ListShortcutsMessage listShortcuts:
                await HandleListShortcutsAsync(listShortcuts);
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
                _ = SessionManager.TrackSession(result.ProcessId.Value, launch.Path);
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

        var result = await _iconService.ExtractIconAsync(
            iconRequest.ExecutablePath,
            iconRequest.PreferredSize,
            token);

        if (result.IsSuccess)
        {
            var iconMessage = SpiceMessageSerializer.CreateIconMessage(
                iconRequest.ExecutablePath,
                result);
            await SendMessageAsync(iconMessage);
            await SendAckAsync(iconRequest.MessageId, success: true);
        }
        else
        {
            _logger.Warn($"Icon extraction failed: {result.ErrorMessage}");
            await SendAckAsync(iconRequest.MessageId, success: false, result.ErrorMessage ?? "Failed to extract icon");
        }
    }

    private async Task HandleShutdownAsync(ShutdownMessage shutdown, CancellationToken _)
    {
        _logger.Info($"Shutdown requested with timeout {shutdown.TimeoutMs}ms");

        // Gracefully stop all sessions
        foreach (var session in SessionManager.GetActiveSessions())
        {
            SessionManager.MarkSessionExited(session.ProcessId);
        }

        await SendAckAsync(shutdown.MessageId, success: true);
    }

    private void HandleMouseInput(MouseInputMessage mouseInput)
    {
        // Record activity for the target window's session
        var session = SessionManager.GetSessionForWindow(mouseInput.WindowId);
        if (session != null)
        {
            SessionManager.RecordActivity(session.ProcessId);
        }

        // Focus window and inject mouse input
        _ = _inputService.FocusWindow(mouseInput.WindowId);
        var success = _inputService.InjectMouse(mouseInput);

        _logger.Debug($"Mouse {mouseInput.EventType} at ({mouseInput.X}, {mouseInput.Y}) for window {mouseInput.WindowId}: {(success ? "OK" : "FAILED")}");
    }

    private void HandleKeyboardInput(KeyboardInputMessage keyboardInput)
    {
        // Record activity for the target window's session
        var session = SessionManager.GetSessionForWindow(keyboardInput.WindowId);
        if (session != null)
        {
            SessionManager.RecordActivity(session.ProcessId);
        }

        // Focus window and inject keyboard input
        _ = _inputService.FocusWindow(keyboardInput.WindowId);
        var success = _inputService.InjectKeyboard(keyboardInput);

        _logger.Debug($"Keyboard {keyboardInput.EventType} key {keyboardInput.KeyCode} for window {keyboardInput.WindowId}: {(success ? "OK" : "FAILED")}");
    }

    private void HandleClipboardData(HostClipboardMessage clipboardData)
    {
        var success = _clipboardService.SetClipboard(clipboardData);
        _logger.Debug($"Clipboard data received: {clipboardData.Format}, {clipboardData.Data.Length} bytes: {(success ? "OK" : "FAILED")}");
    }

    private void HandleDragDrop(DragDropMessage dragDrop)
    {
        // Record activity
        var session = SessionManager.GetSessionForWindow(dragDrop.WindowId);
        if (session != null)
        {
            SessionManager.RecordActivity(session.ProcessId);
        }

        // Process drag/drop event
        var result = _dragDropService.HandleDragDrop(dragDrop);

        if (result.Success)
        {
            _logger.Debug($"DragDrop {dragDrop.EventType} for window {dragDrop.WindowId}: {result.StagedPaths.Length} files staged");
        }
        else
        {
            _logger.Warn($"DragDrop {dragDrop.EventType} failed for window {dragDrop.WindowId}: {result.ErrorMessage}");
        }
    }

    private async Task HandleListSessionsAsync(ListSessionsMessage request)
    {
        _logger.Debug("Listing active sessions");

        var sessions = SessionManager.GetActiveSessions();
        var response = SpiceMessageSerializer.CreateSessionList(request.MessageId, sessions);

        _logger.Info($"Returning {response.Sessions.Length} active sessions");
        await SendMessageAsync(response);
    }

    private async Task HandleCloseSessionAsync(CloseSessionMessage request)
    {
        _logger.Info($"Close session requested: {request.SessionId}");

        // Parse session ID (which is the process ID as a string)
        if (!int.TryParse(request.SessionId, out var processId))
        {
            _logger.Warn($"Invalid session ID format: {request.SessionId}");
            await SendAckAsync(request.MessageId, success: false, $"Invalid session ID: {request.SessionId}");
            return;
        }

        var session = SessionManager.GetSession(processId);
        if (session == null)
        {
            _logger.Warn($"Session not found: {request.SessionId}");
            await SendAckAsync(request.MessageId, success: false, $"Session not found: {request.SessionId}");
            return;
        }

        // Mark session as exited (this will notify host via existing event handling)
        SessionManager.MarkSessionExited(processId);

        _logger.Info($"Session {request.SessionId} closed");
        await SendAckAsync(request.MessageId, success: true);
    }

    private async Task HandleListShortcutsAsync(ListShortcutsMessage request)
    {
        _logger.Debug("Listing detected shortcuts");

        // Parse all known shortcuts to get their full info
        var shortcuts = new List<ShortcutInfo>();
        foreach (var path in ShortcutService.KnownShortcuts)
        {
            var info = ShortcutService.ParseShortcut(path);
            if (info != null)
            {
                shortcuts.Add(info);
            }
        }

        var response = SpiceMessageSerializer.CreateShortcutList(request.MessageId, shortcuts);

        _logger.Info($"Returning {response.Shortcuts.Length} detected shortcuts");
        await SendMessageAsync(response);
    }

    private async Task SendCapabilityAnnouncementAsync()
    {
        var capabilities =
            GuestCapabilities.WindowTracking |
            GuestCapabilities.IconExtraction |
            GuestCapabilities.ClipboardSync |
            GuestCapabilities.DragDrop |
            GuestCapabilities.ShortcutDetection |
            GuestCapabilities.HighDpiSupport;

        // Add DesktopDuplication capability if frame streaming is enabled
        if (FrameStreaming != null)
        {
            capabilities |= GuestCapabilities.DesktopDuplication;
        }

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

    private async Task SendMessageAsync(GuestMessage message) => await SendMessageAsync(message, RetryPolicy.Default);

    private async Task SendMessageAsync(GuestMessage message, RetryPolicy policy)
    {
        var success = await Telemetry.SendWithRetryAsync(_outboundChannel.Writer, message, policy);
        if (!success)
        {
            _logger.Error($"Failed to send {message.GetType().Name} after all retry attempts");
        }
    }

    private void OnWindowEvent(object? sender, WindowEventArgs e)
    {
        _logger.Debug($"Window {e.WindowId} {e.EventType}: \"{e.Title}\" {e.Bounds}");

        // Send window metadata to host
        var metadata = SpiceMessageSerializer.CreateWindowMetadata(e);
        _ = SendMessageAsync(metadata);
    }

    private void OnSessionStateChanged(object? sender, SessionStateChangedEventArgs e) => _logger.Info($"Session {e.Session.ProcessId} state: {e.PreviousState} -> {e.NewState}");

    private void OnClipboardChanged(object? sender, GuestClipboardMessage e) => _logger.Debug($"Guest clipboard changed: {e.Format}, {e.Data.Length} bytes");

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        FrameStreaming?.Dispose();
        Telemetry.Dispose();
        ShortcutService.Dispose();
        SessionManager.Dispose();
        _clipboardService.Dispose();
        _dragDropService.Dispose();
        _launcher.Dispose();
        _windowTracker.Dispose();
        _disposed = true;
    }
}
