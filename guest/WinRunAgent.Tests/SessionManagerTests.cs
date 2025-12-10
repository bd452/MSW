using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class SessionManagerTests : IDisposable
{
    private readonly TestLogger _logger = new();
    private readonly ProgramLauncher _launcher;
    private readonly WindowTracker _windowTracker;
    private readonly SessionManager _sessionManager;

    public SessionManagerTests()
    {
        _launcher = new ProgramLauncher(_logger);
        _windowTracker = new WindowTracker(_logger);
        _sessionManager = new SessionManager(_logger, _launcher, _windowTracker);
    }

    public void Dispose()
    {
        _sessionManager.Dispose();
        _launcher.Dispose();
        _windowTracker.Dispose();
    }

    [Fact]
    public void TrackSession_CreatesNewSession()
    {
        var session = _sessionManager.TrackSession(1234, @"C:\App.exe");

        Assert.NotNull(session);
        Assert.Equal(1234, session.ProcessId);
        Assert.Equal(@"C:\App.exe", session.ExecutablePath);
        Assert.Equal(SessionState.Starting, session.State);
        Assert.False(session.HasWindows);
    }

    [Fact]
    public void TrackSession_SameProcessIdReturnsSameSession()
    {
        var session1 = _sessionManager.TrackSession(1234, @"C:\App.exe");
        var session2 = _sessionManager.TrackSession(1234, @"C:\App.exe");

        Assert.Same(session1, session2);
    }

    [Fact]
    public void GetActiveSessions_InitiallyEmpty()
    {
        var sessions = _sessionManager.GetActiveSessions();

        Assert.Empty(sessions);
    }

    [Fact]
    public void GetActiveSessions_ReturnsTrackedSessions()
    {
        _ = _sessionManager.TrackSession(1234, @"C:\App1.exe");
        _ = _sessionManager.TrackSession(5678, @"C:\App2.exe");

        var sessions = _sessionManager.GetActiveSessions();

        Assert.Equal(2, sessions.Count);
    }

    [Fact]
    public void GetSession_ReturnsNullForUnknownProcess()
    {
        var session = _sessionManager.GetSession(9999);

        Assert.Null(session);
    }

    [Fact]
    public void GetSession_ReturnsSessionForKnownProcess()
    {
        _ = _sessionManager.TrackSession(1234, @"C:\App.exe");

        var session = _sessionManager.GetSession(1234);

        Assert.NotNull(session);
        Assert.Equal(1234, session.ProcessId);
    }

    [Fact]
    public void MarkSessionExited_ChangesState()
    {
        _ = _sessionManager.TrackSession(1234, @"C:\App.exe");

        _sessionManager.MarkSessionExited(1234);

        var session = _sessionManager.GetSession(1234);
        Assert.NotNull(session);
        Assert.Equal(SessionState.Exited, session.State);
    }

    [Fact]
    public void RecordActivity_UpdatesSession()
    {
        var session = _sessionManager.TrackSession(1234, @"C:\App.exe");
        var initialActivity = session.LastActivityTime;

        Thread.Sleep(10); // Ensure time passes
        _sessionManager.RecordActivity(1234);

        Assert.True(session.LastActivityTime > initialActivity);
    }

    [Fact]
    public void AssociateWindow_LinksWindowToSession()
    {
        var session = _sessionManager.TrackSession(1234, @"C:\App.exe");

        _sessionManager.AssociateWindow(100UL, 1234);

        Assert.True(session.HasWindows);
        Assert.Contains(100UL, session.WindowIds);
        Assert.Equal(SessionState.Active, session.State);
    }

    [Fact]
    public void DisassociateWindow_RemovesWindowFromSession()
    {
        var session = _sessionManager.TrackSession(1234, @"C:\App.exe");
        _sessionManager.AssociateWindow(100UL, 1234);

        _sessionManager.DisassociateWindow(100UL);

        Assert.DoesNotContain(100UL, session.WindowIds);
    }

    [Fact]
    public void GetSessionForWindow_ReturnsCorrectSession()
    {
        _ = _sessionManager.TrackSession(1234, @"C:\App.exe");
        _sessionManager.AssociateWindow(100UL, 1234);

        var session = _sessionManager.GetSessionForWindow(100UL);

        Assert.NotNull(session);
        Assert.Equal(1234, session.ProcessId);
    }

    [Fact]
    public void GetSessionForWindow_ReturnsNullForUnknownWindow()
    {
        var session = _sessionManager.GetSessionForWindow(999UL);

        Assert.Null(session);
    }

    [Fact]
    public void GenerateHeartbeat_ReturnsValidMessage()
    {
        _ = _sessionManager.TrackSession(1234, @"C:\App.exe");
        _sessionManager.AssociateWindow(100UL, 1234);

        var heartbeat = _sessionManager.GenerateHeartbeat();

        Assert.Equal(1, heartbeat.TrackedWindowCount);
        Assert.True(heartbeat.UptimeMs >= 0);
    }

    [Fact]
    public void SessionStateChanged_RaisedOnStateTransition()
    {
        var events = new List<SessionStateChangedEventArgs>();
        _sessionManager.SessionStateChanged += (_, e) => events.Add(e);

        var session = _sessionManager.TrackSession(1234, @"C:\App.exe");
        _sessionManager.AssociateWindow(100UL, 1234); // Triggers Starting -> Active

        Assert.Contains(events, e => e.NewState == SessionState.Active);
    }

    [Fact]
    public async Task HeartbeatDue_RaisedWhenStarted()
    {
        // Create session manager with custom heartbeat interval
        using var launcher = new ProgramLauncher(_logger);
        using var windowTracker = new WindowTracker(_logger);
        using var sessionManager = new SessionManager(_logger, launcher, windowTracker)
        {
            HeartbeatInterval = TimeSpan.FromMilliseconds(50)
        };

        var heartbeatReceived = new TaskCompletionSource<HeartbeatMessage>();
        sessionManager.HeartbeatDue += (_, e) => heartbeatReceived.TrySetResult(e.Heartbeat);

        sessionManager.Start();

        try
        {
            var timeoutTask = Task.Delay(TimeSpan.FromMilliseconds(200));
            var completedTask = await Task.WhenAny(heartbeatReceived.Task, timeoutTask);
            Assert.True(completedTask == heartbeatReceived.Task, "Heartbeat event should be raised");
        }
        finally
        {
            sessionManager.Stop();
        }
    }

    [Fact]
    public void ProgramSession_IdleTime_CalculatesCorrectly()
    {
        var session = new ProgramSession(1234, @"C:\App.exe");

        Thread.Sleep(50);

        Assert.True(session.IdleTime >= TimeSpan.FromMilliseconds(50));
    }

    [Fact]
    public void ProgramSession_Uptime_CalculatesCorrectly()
    {
        var session = new ProgramSession(1234, @"C:\App.exe");

        Thread.Sleep(50);

        Assert.True(session.Uptime >= TimeSpan.FromMilliseconds(50));
    }

    [Fact]
    public void ProgramSession_AddWindow_SetsActiveState()
    {
        var session = new ProgramSession(1234, @"C:\App.exe");
        Assert.Equal(SessionState.Starting, session.State);

        session.AddWindow(100UL);

        Assert.Equal(SessionState.Active, session.State);
        Assert.Equal(1, session.WindowCount);
    }

    [Fact]
    public void ProgramSession_RemoveWindow_ReducesCount()
    {
        var session = new ProgramSession(1234, @"C:\App.exe");
        session.AddWindow(100UL);
        session.AddWindow(200UL);

        session.RemoveWindow(100UL);

        Assert.Equal(1, session.WindowCount);
        Assert.Contains(200UL, session.WindowIds);
    }

    [Fact]
    public void ProgramSession_MarkIdle_SetsIdleState()
    {
        var session = new ProgramSession(1234, @"C:\App.exe");
        session.AddWindow(100UL);

        session.MarkIdle();

        Assert.Equal(SessionState.Idle, session.State);
    }

    [Fact]
    public void ProgramSession_MarkActive_SetsActiveStateAndRecordsActivity()
    {
        var session = new ProgramSession(1234, @"C:\App.exe");
        session.MarkIdle();
        var before = session.LastActivityTime;

        Thread.Sleep(10);
        session.MarkActive();

        Assert.Equal(SessionState.Active, session.State);
        Assert.True(session.LastActivityTime > before);
    }

    [Fact]
    public void ProgramSession_MarkExited_SetsExitedState()
    {
        var session = new ProgramSession(1234, @"C:\App.exe");

        session.MarkExited();

        Assert.Equal(SessionState.Exited, session.State);
    }

    [Fact]
    public void SessionState_HasExpectedValues()
    {
        Assert.Equal(0, (int)SessionState.Starting);
        Assert.Equal(1, (int)SessionState.Active);
        Assert.Equal(2, (int)SessionState.Idle);
        Assert.Equal(3, (int)SessionState.Exited);
    }

    private sealed class TestLogger : IAgentLogger
    {
        public void Debug(string message) { }
        public void Info(string message) { }
        public void Warn(string message) { }
        public void Error(string message) { }
    }
}

