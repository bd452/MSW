using System.Collections.Concurrent;
using System.Diagnostics;

namespace WinRun.Agent.Services;

/// <summary>
/// Represents an active program session being tracked by the agent.
/// </summary>
public sealed class ProgramSession
{
    public int ProcessId { get; }
    public string ExecutablePath { get; }
    public DateTime StartTime { get; }
    public DateTime LastActivityTime { get; private set; }
    public SessionState State { get; private set; }

    /// <summary>
    /// Windows associated with this session (HWND values).
    /// </summary>
    private readonly HashSet<ulong> _windowIds = [];

    public IReadOnlySet<ulong> WindowIds => _windowIds;
    public int WindowCount => _windowIds.Count;
    public bool HasWindows => _windowIds.Count > 0;

    public TimeSpan IdleTime => DateTime.UtcNow - LastActivityTime;
    public TimeSpan Uptime => DateTime.UtcNow - StartTime;

    public ProgramSession(int processId, string executablePath)
    {
        ProcessId = processId;
        ExecutablePath = executablePath;
        StartTime = DateTime.UtcNow;
        LastActivityTime = DateTime.UtcNow;
        State = SessionState.Starting;
    }

    public void RecordActivity() => LastActivityTime = DateTime.UtcNow;

    public void AddWindow(ulong windowId)
    {
        _ = _windowIds.Add(windowId);
        RecordActivity();
        if (State == SessionState.Starting)
        {
            State = SessionState.Active;
        }
    }

    public void RemoveWindow(ulong windowId)
    {
        _ = _windowIds.Remove(windowId);
        RecordActivity();
    }

    public void MarkIdle() => State = SessionState.Idle;

    public void MarkActive()
    {
        State = SessionState.Active;
        RecordActivity();
    }

    public void MarkExited() => State = SessionState.Exited;
}

/// <summary>
/// Session lifecycle states.
/// </summary>
public enum SessionState
{
    Starting,
    Active,
    Idle,
    Exited
}

/// <summary>
/// Manages active program sessions, heartbeats, and idle detection.
/// </summary>
public sealed class SessionManager : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly ProgramLauncher _launcher;
    private readonly WindowTracker _windowTracker;
    private readonly ConcurrentDictionary<int, ProgramSession> _sessions = new();
    private readonly ConcurrentDictionary<ulong, int> _windowToProcess = new();

    private readonly Timer _heartbeatTimer;
    private readonly Timer _idleCheckTimer;
    private readonly Stopwatch _uptimeStopwatch;

    private readonly Func<GuestMessage, Task>? _sendMessage;
    private bool _disposed;

    /// <summary>
    /// Interval between heartbeat messages.
    /// </summary>
    public TimeSpan HeartbeatInterval { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Duration after which a session is considered idle if no activity.
    /// </summary>
    public TimeSpan IdleThreshold { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Duration after which an idle session may be cleaned up.
    /// </summary>
    public TimeSpan IdleTimeout { get; init; } = TimeSpan.FromMinutes(30);

    /// <summary>
    /// Event raised when a session's state changes.
    /// </summary>
    public event EventHandler<SessionStateChangedEventArgs>? SessionStateChanged;

    /// <summary>
    /// Event raised when a heartbeat is due.
    /// </summary>
    public event EventHandler<HeartbeatEventArgs>? HeartbeatDue;

    public SessionManager(
        IAgentLogger logger,
        ProgramLauncher launcher,
        WindowTracker windowTracker,
        Func<GuestMessage, Task>? sendMessage = null)
    {
        _logger = logger;
        _launcher = launcher;
        _windowTracker = windowTracker;
        _sendMessage = sendMessage;
        _uptimeStopwatch = Stopwatch.StartNew();

        _heartbeatTimer = new Timer(OnHeartbeatTimer, null, Timeout.Infinite, Timeout.Infinite);
        _idleCheckTimer = new Timer(OnIdleCheckTimer, null, Timeout.Infinite, Timeout.Infinite);
    }

    /// <summary>
    /// Starts session tracking, heartbeats, and idle detection.
    /// </summary>
    public void Start()
    {
        _logger.Info("SessionManager starting");

        // Subscribe to window tracker events
        _windowTracker.WindowEvent += OnWindowEvent;

        // Subscribe to process exit events from launcher
        foreach (var info in _launcher.GetTrackedProcesses())
        {
            _ = TrackSession(info.ProcessId, info.ExecutablePath);
        }

        // Start timers
        _ = _heartbeatTimer.Change(HeartbeatInterval, HeartbeatInterval);
        _ = _idleCheckTimer.Change(TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(1));

        _logger.Info($"SessionManager started with heartbeat interval {HeartbeatInterval}");
    }

    /// <summary>
    /// Stops session tracking.
    /// </summary>
    public void Stop()
    {
        _ = _heartbeatTimer.Change(Timeout.Infinite, Timeout.Infinite);
        _ = _idleCheckTimer.Change(Timeout.Infinite, Timeout.Infinite);
        _windowTracker.WindowEvent -= OnWindowEvent;

        _logger.Info("SessionManager stopped");
    }

    /// <summary>
    /// Tracks a newly launched program session.
    /// </summary>
    public ProgramSession TrackSession(int processId, string executablePath)
    {
        var session = new ProgramSession(processId, executablePath);

        if (_sessions.TryAdd(processId, session))
        {
            _logger.Info($"Tracking new session: PID {processId} ({Path.GetFileName(executablePath)})");
            RaiseSessionStateChanged(session, SessionState.Starting, SessionState.Starting);
        }

        return _sessions[processId];
    }

    /// <summary>
    /// Marks a session as exited.
    /// </summary>
    public void MarkSessionExited(int processId)
    {
        if (_sessions.TryGetValue(processId, out var session))
        {
            var previousState = session.State;
            session.MarkExited();

            _logger.Info($"Session exited: PID {processId} (uptime: {session.Uptime:hh\\:mm\\:ss})");
            RaiseSessionStateChanged(session, previousState, SessionState.Exited);

            // Clean up window mappings
            foreach (var windowId in session.WindowIds.ToList())
            {
                _ = _windowToProcess.TryRemove(windowId, out _);
            }

            // Remove from active sessions after a delay to allow for late events
            _ = Task.Delay(TimeSpan.FromSeconds(5)).ContinueWith(t =>
            {
                _ = _sessions.TryRemove(processId, out _);
            });
        }
    }

    /// <summary>
    /// Records activity for a session.
    /// </summary>
    public void RecordActivity(int processId)
    {
        if (_sessions.TryGetValue(processId, out var session))
        {
            var wasIdle = session.State == SessionState.Idle;
            session.RecordActivity();

            if (wasIdle)
            {
                session.MarkActive();
                RaiseSessionStateChanged(session, SessionState.Idle, SessionState.Active);
            }
        }
    }

    /// <summary>
    /// Associates a window with a process session.
    /// </summary>
    public void AssociateWindow(ulong windowId, int processId)
    {
        _windowToProcess[windowId] = processId;

        if (_sessions.TryGetValue(processId, out var session))
        {
            var previousState = session.State;
            session.AddWindow(windowId);

            if (previousState == SessionState.Starting && session.State == SessionState.Active)
            {
                RaiseSessionStateChanged(session, SessionState.Starting, SessionState.Active);
            }
        }
    }

    /// <summary>
    /// Removes a window association.
    /// </summary>
    public void DisassociateWindow(ulong windowId)
    {
        if (_windowToProcess.TryRemove(windowId, out var processId))
        {
            if (_sessions.TryGetValue(processId, out var session))
            {
                session.RemoveWindow(windowId);
            }
        }
    }

    /// <summary>
    /// Gets all active sessions.
    /// </summary>
    public IReadOnlyCollection<ProgramSession> GetActiveSessions() =>
        [.. _sessions.Values.Where(s => s.State != SessionState.Exited)];

    /// <summary>
    /// Gets a session by process ID.
    /// </summary>
    public ProgramSession? GetSession(int processId) => _sessions.TryGetValue(processId, out var session) ? session : null;

    /// <summary>
    /// Gets the session for a window.
    /// </summary>
    public ProgramSession? GetSessionForWindow(ulong windowId) => _windowToProcess.TryGetValue(windowId, out var processId)
            ? GetSession(processId)
            : null;

    /// <summary>
    /// Generates a heartbeat message with current metrics.
    /// </summary>
    public HeartbeatMessage GenerateHeartbeat()
    {
        var activeSessions = GetActiveSessions();
        var totalWindowCount = activeSessions.Sum(s => s.WindowCount);

        var (cpuUsage, memoryUsage) = GetProcessMetrics();

        return new HeartbeatMessage
        {
            TrackedWindowCount = totalWindowCount,
            UptimeMs = _uptimeStopwatch.ElapsedMilliseconds,
            CpuUsagePercent = cpuUsage,
            MemoryUsageBytes = memoryUsage
        };
    }

    private void OnHeartbeatTimer(object? state)
    {
        try
        {
            var heartbeat = GenerateHeartbeat();
            var args = new HeartbeatEventArgs(heartbeat);

            HeartbeatDue?.Invoke(this, args);

            if (_sendMessage != null)
            {
                _ = _sendMessage(heartbeat);
            }

            _logger.Debug($"Heartbeat: {heartbeat.TrackedWindowCount} windows, " +
                $"uptime {TimeSpan.FromMilliseconds(heartbeat.UptimeMs):hh\\:mm\\:ss}, " +
                $"CPU {heartbeat.CpuUsagePercent:F1}%, " +
                $"mem {heartbeat.MemoryUsageBytes / (1024 * 1024)}MB");
        }
        catch (Exception ex)
        {
            _logger.Error($"Error generating heartbeat: {ex.Message}");
        }
    }

    private void OnIdleCheckTimer(object? state)
    {
        try
        {
            var now = DateTime.UtcNow;

            foreach (var session in _sessions.Values)
            {
                if (session.State == SessionState.Exited)
                {
                    continue;
                }

                var idleTime = session.IdleTime;

                // Check if session should be marked idle
                if (session.State == SessionState.Active && idleTime >= IdleThreshold)
                {
                    session.MarkIdle();
                    _logger.Info($"Session {session.ProcessId} marked idle (idle time: {idleTime:hh\\:mm\\:ss})");
                    RaiseSessionStateChanged(session, SessionState.Active, SessionState.Idle);
                }

                // Check if idle session should timeout
                if (session.State == SessionState.Idle && idleTime >= IdleTimeout)
                {
                    _logger.Warn($"Session {session.ProcessId} exceeded idle timeout (idle: {idleTime:hh\\:mm\\:ss})");
                    // Note: We don't automatically kill sessions; the host decides what to do
                    // Just raise an event and let the host handle it
                }
            }

            // Clean up exited sessions that have been hanging around
            var exitedSessionIds = _sessions
                .Where(kvp => kvp.Value.State == SessionState.Exited)
                .Select(kvp => kvp.Key)
                .ToList();

            foreach (var processId in exitedSessionIds)
            {
                _ = _sessions.TryRemove(processId, out _);
            }
        }
        catch (Exception ex)
        {
            _logger.Error($"Error in idle check: {ex.Message}");
        }
    }

    private void OnWindowEvent(object? sender, WindowEventArgs e)
    {
        switch (e.EventType)
        {
            case WindowEventType.Created:
                // Try to find which session owns this window
                var launcherInfo = _launcher.GetTrackedProcesses()
                    .FirstOrDefault(p => IsWindowOwnedByProcess(e.WindowId, p.ProcessId));

                if (launcherInfo != null)
                {
                    AssociateWindow(e.WindowId, launcherInfo.ProcessId);
                }
                break;

            case WindowEventType.Destroyed:
                DisassociateWindow(e.WindowId);
                break;

            case WindowEventType.Updated:
            case WindowEventType.FocusChanged:
                var session = GetSessionForWindow(e.WindowId);
                if (session != null)
                {
                    RecordActivity(session.ProcessId);
                }
                break;
            case WindowEventType.Moved:
                break;
            case WindowEventType.TitleChanged:
                break;
            case WindowEventType.Minimized:
                break;
            case WindowEventType.Restored:
                break;
            default:
                break;
        }
    }

    private static bool IsWindowOwnedByProcess(ulong windowId, int processId)
    {
        // On Windows, we would use GetWindowThreadProcessId
        // For now, this is a placeholder that returns false
        // The actual implementation requires P/Invoke on Windows
        _ = windowId;
        _ = processId;
        return false;
    }

    private static (float CpuPercent, long MemoryBytes) GetProcessMetrics()
    {
        try
        {
            using var process = Process.GetCurrentProcess();
            var memoryBytes = process.WorkingSet64;

            // CPU percentage is harder to calculate accurately
            // For now, return 0 and let the host calculate from periodic samples
            return (0f, memoryBytes);
        }
        catch
        {
            return (0f, 0);
        }
    }

    private void RaiseSessionStateChanged(ProgramSession session, SessionState previousState, SessionState newState) => SessionStateChanged?.Invoke(this, new SessionStateChangedEventArgs(session, previousState, newState));

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        Stop();
        _heartbeatTimer.Dispose();
        _idleCheckTimer.Dispose();
        _disposed = true;
    }
}

/// <summary>
/// Event args for session state changes.
/// </summary>
public sealed class SessionStateChangedEventArgs : EventArgs
{
    public ProgramSession Session { get; }
    public SessionState PreviousState { get; }
    public SessionState NewState { get; }

    public SessionStateChangedEventArgs(ProgramSession session, SessionState previousState, SessionState newState)
    {
        Session = session;
        PreviousState = previousState;
        NewState = newState;
    }
}

/// <summary>
/// Event args for heartbeat events.
/// </summary>
public sealed class HeartbeatEventArgs : EventArgs
{
    public HeartbeatMessage Heartbeat { get; }

    public HeartbeatEventArgs(HeartbeatMessage heartbeat)
    {
        Heartbeat = heartbeat;
    }
}

