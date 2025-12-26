using System.Threading.Channels;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class WinRunAgentServiceTests : IDisposable
{
    private readonly TestLogger _logger = new();
    private readonly WindowTracker _windowTracker;
    private readonly ProgramLauncher _launcher;
    private readonly IconExtractionService _iconService;
    private readonly Channel<HostMessage> _inboundChannel;
    private readonly WinRunAgentService _service;

    public WinRunAgentServiceTests()
    {
        _windowTracker = new WindowTracker(_logger);
        _launcher = new ProgramLauncher(_logger);
        _iconService = new IconExtractionService(_logger);
        _inboundChannel = Channel.CreateUnbounded<HostMessage>();

        _service = new WinRunAgentService(
            _windowTracker,
            _launcher,
            _iconService,
            _inboundChannel,
            _logger);
    }

    public void Dispose() => _service.Dispose();

    [Fact]
    public void SessionManager_IsExposed() => Assert.NotNull(_service.SessionManager);

    [Fact]
    public async Task RunAsync_SendsCapabilityAnnouncement()
    {
        // Create service with accessible outbound channel
        using var windowTracker = new WindowTracker(_logger);
        using var launcher = new ProgramLauncher(_logger);
        var iconService = new IconExtractionService(_logger);
        var inputService = new InputInjectionService(_logger);
        using var clipboardService = new ClipboardSyncService(_logger);
        using var shortcutService = new ShortcutSyncService(_logger, _ => { });
        using var dragDropService = new DragDropService(_logger);
        var inbound = Channel.CreateUnbounded<HostMessage>();
        var outbound = Channel.CreateUnbounded<GuestMessage>();

        using var service = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inputService,
            clipboardService,
            shortcutService,
            dragDropService,
            inbound,
            outbound,
            _logger);

        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(100));

        try
        {
            await service.RunAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected - we cancelled after startup
        }

        // Check that a capability message was sent
        var reader = outbound.Reader;
        Assert.True(reader.TryRead(out var message));
        var capabilities = Assert.IsType<CapabilityFlagsMessage>(message);
        Assert.True(capabilities.Capabilities.HasFlag(GuestCapabilities.WindowTracking));
    }

    [Fact]
    public async Task HandleLaunchProgram_SendsAckOnFailure()
    {
        using var windowTracker = new WindowTracker(_logger);
        using var launcher = new ProgramLauncher(_logger);
        var iconService = new IconExtractionService(_logger);
        var inputService = new InputInjectionService(_logger);
        using var clipboardService = new ClipboardSyncService(_logger);
        using var shortcutService = new ShortcutSyncService(_logger, _ => { });
        using var dragDropService = new DragDropService(_logger);
        var inbound = Channel.CreateUnbounded<HostMessage>();
        var outbound = Channel.CreateUnbounded<GuestMessage>();

        using var service = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inputService,
            clipboardService,
            shortcutService,
            dragDropService,
            inbound,
            outbound,
            _logger);

        // Queue a launch message for a non-existent path
        var launchMessage = new LaunchProgramMessage
        {
            MessageId = 42,
            Path = @"C:\NonExistent\App.exe"
        };
        await inbound.Writer.WriteAsync(launchMessage);

        // Allow enough time for shortcut scanning + message processing on CI
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(2000));

        try
        {
            await service.RunAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }

        // Find the ACK message
        var reader = outbound.Reader;
        AckMessage? ack = null;
        while (reader.TryRead(out var msg))
        {
            if (msg is AckMessage a && a.MessageId == 42)
            {
                ack = a;
                break;
            }
        }

        Assert.NotNull(ack);
        Assert.False(ack.Success);
        Assert.NotNull(ack.ErrorMessage);
    }

    [Fact]
    public async Task HandleIconRequest_SendsAckOnEmptyIcon()
    {
        using var windowTracker = new WindowTracker(_logger);
        using var launcher = new ProgramLauncher(_logger);
        var iconService = new IconExtractionService(_logger);
        var inputService = new InputInjectionService(_logger);
        using var clipboardService = new ClipboardSyncService(_logger);
        using var shortcutService = new ShortcutSyncService(_logger, _ => { });
        using var dragDropService = new DragDropService(_logger);
        var inbound = Channel.CreateUnbounded<HostMessage>();
        var outbound = Channel.CreateUnbounded<GuestMessage>();

        using var service = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inputService,
            clipboardService,
            shortcutService,
            dragDropService,
            inbound,
            outbound,
            _logger);

        // Queue an icon request for a non-existent path
        var iconRequest = new RequestIconMessage
        {
            MessageId = 99,
            ExecutablePath = @"C:\NonExistent\App.exe"
        };
        await inbound.Writer.WriteAsync(iconRequest);

        // Allow enough time for shortcut scanning + message processing on CI
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(2000));

        try
        {
            await service.RunAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }

        // Find the ACK message
        var reader = outbound.Reader;
        AckMessage? ack = null;
        while (reader.TryRead(out var msg))
        {
            if (msg is AckMessage a && a.MessageId == 99)
            {
                ack = a;
                break;
            }
        }

        Assert.NotNull(ack);
        Assert.False(ack.Success);
    }

    [Fact]
    public void BackwardCompatibilityConstructor_CreatesAllServices()
    {
        using var windowTracker = new WindowTracker(_logger);
        using var launcher = new ProgramLauncher(_logger);
        var iconService = new IconExtractionService(_logger);
        var inbound = Channel.CreateUnbounded<HostMessage>();

        // Use backward-compatible constructor
        using var service = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inbound,
            _logger);

        Assert.NotNull(service.SessionManager);
    }

    [Fact]
    public async Task HandleCloseSession_SendsSuccessAckForExistingSession()
    {
        using var windowTracker = new WindowTracker(_logger);
        using var launcher = new ProgramLauncher(_logger);
        var iconService = new IconExtractionService(_logger);
        var inputService = new InputInjectionService(_logger);
        using var clipboardService = new ClipboardSyncService(_logger);
        using var shortcutService = new ShortcutSyncService(_logger, _ => { });
        using var dragDropService = new DragDropService(_logger);
        var inbound = Channel.CreateUnbounded<HostMessage>();
        var outbound = Channel.CreateUnbounded<GuestMessage>();

        using var service = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inputService,
            clipboardService,
            shortcutService,
            dragDropService,
            inbound,
            outbound,
            _logger);

        // Track a session first
        var session = service.SessionManager.TrackSession(1234, @"C:\App.exe");
        Assert.NotNull(session);

        // Send close session message
        var closeMessage = new CloseSessionMessage
        {
            MessageId = 200,
            SessionId = "1234"  // Process ID as string
        };
        await inbound.Writer.WriteAsync(closeMessage);

        // Allow enough time for shortcut scanning + message processing
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(2000));

        try
        {
            await service.RunAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }

        // Find the ACK message
        var reader = outbound.Reader;
        AckMessage? ack = null;
        while (reader.TryRead(out var msg))
        {
            if (msg is AckMessage a && a.MessageId == 200)
            {
                ack = a;
                break;
            }
        }

        Assert.NotNull(ack);
        Assert.True(ack.Success);
        Assert.Null(ack.ErrorMessage);

        // Verify session was marked as exited
        var closedSession = service.SessionManager.GetSession(1234);
        Assert.NotNull(closedSession);
        Assert.Equal(SessionState.Exited, closedSession.State);
    }

    [Fact]
    public async Task HandleCloseSession_SendsFailureAckForInvalidSessionId()
    {
        using var windowTracker = new WindowTracker(_logger);
        using var launcher = new ProgramLauncher(_logger);
        var iconService = new IconExtractionService(_logger);
        var inputService = new InputInjectionService(_logger);
        using var clipboardService = new ClipboardSyncService(_logger);
        using var shortcutService = new ShortcutSyncService(_logger, _ => { });
        using var dragDropService = new DragDropService(_logger);
        var inbound = Channel.CreateUnbounded<HostMessage>();
        var outbound = Channel.CreateUnbounded<GuestMessage>();

        using var service = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inputService,
            clipboardService,
            shortcutService,
            dragDropService,
            inbound,
            outbound,
            _logger);

        // Send close session message with non-numeric session ID
        var closeMessage = new CloseSessionMessage
        {
            MessageId = 201,
            SessionId = "not-a-number"
        };
        await inbound.Writer.WriteAsync(closeMessage);

        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(2000));

        try
        {
            await service.RunAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }

        // Find the ACK message
        var reader = outbound.Reader;
        AckMessage? ack = null;
        while (reader.TryRead(out var msg))
        {
            if (msg is AckMessage a && a.MessageId == 201)
            {
                ack = a;
                break;
            }
        }

        Assert.NotNull(ack);
        Assert.False(ack.Success);
        Assert.Contains("Invalid session ID", ack.ErrorMessage);
    }

    [Fact]
    public async Task HandleCloseSession_SendsFailureAckForNonexistentSession()
    {
        using var windowTracker = new WindowTracker(_logger);
        using var launcher = new ProgramLauncher(_logger);
        var iconService = new IconExtractionService(_logger);
        var inputService = new InputInjectionService(_logger);
        using var clipboardService = new ClipboardSyncService(_logger);
        using var shortcutService = new ShortcutSyncService(_logger, _ => { });
        using var dragDropService = new DragDropService(_logger);
        var inbound = Channel.CreateUnbounded<HostMessage>();
        var outbound = Channel.CreateUnbounded<GuestMessage>();

        using var service = new WinRunAgentService(
            windowTracker,
            launcher,
            iconService,
            inputService,
            clipboardService,
            shortcutService,
            dragDropService,
            inbound,
            outbound,
            _logger);

        // Send close session message for session that doesn't exist
        var closeMessage = new CloseSessionMessage
        {
            MessageId = 202,
            SessionId = "99999"
        };
        await inbound.Writer.WriteAsync(closeMessage);

        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(2000));

        try
        {
            await service.RunAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected
        }

        // Find the ACK message
        var reader = outbound.Reader;
        AckMessage? ack = null;
        while (reader.TryRead(out var msg))
        {
            if (msg is AckMessage a && a.MessageId == 202)
            {
                ack = a;
                break;
            }
        }

        Assert.NotNull(ack);
        Assert.False(ack.Success);
        Assert.Contains("Session not found", ack.ErrorMessage);
    }

}

