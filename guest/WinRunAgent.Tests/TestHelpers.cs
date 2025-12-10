using System.Runtime.CompilerServices;
using WinRun.Agent.Services;

namespace WinRun.Agent.Tests;

/// <summary>
/// A test logger that captures log messages for assertions.
/// </summary>
public sealed class TestLogger : IAgentLogger
{
    public List<LogEntry> Entries { get; } = [];

    /// <summary>All messages (for backward compatibility).</summary>
    public List<string> Messages => [.. Entries.Select(e => e.Message)];

    public List<string> DebugMessages => [.. Entries.Where(e => e.Level == LogLevel.Debug).Select(e => e.Message)];
    public List<string> InfoMessages => [.. Entries.Where(e => e.Level == LogLevel.Info).Select(e => e.Message)];
    public List<string> WarnMessages => [.. Entries.Where(e => e.Level == LogLevel.Warn).Select(e => e.Message)];
    public List<string> ErrorMessages => [.. Entries.Where(e => e.Level == LogLevel.Error).Select(e => e.Message)];

    public LogLevel MinimumLevel { get; set; } = LogLevel.Debug;

    public void Log(
        LogLevel level,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0)
    {
        if (level < MinimumLevel)
        {
            return;
        }

        Entries.Add(new LogEntry(level, message, metadata, file, function, line));
    }

    /// <summary>Clears all captured log entries.</summary>
    public void Clear() => Entries.Clear();

    /// <summary>
    /// A captured log entry.
    /// </summary>
    public sealed record LogEntry(
        LogLevel Level,
        string Message,
        LogMetadata? Metadata,
        string File,
        string Function,
        int Line);
}

/// <summary>
/// A no-op logger for tests that don't need to capture logs.
/// </summary>
public sealed class NullLogger : IAgentLogger
{
    public static readonly NullLogger Instance = new();

    public LogLevel MinimumLevel { get; set; } = LogLevel.Debug;

    public void Log(
        LogLevel level,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0)
    {
        // No-op
    }
}
