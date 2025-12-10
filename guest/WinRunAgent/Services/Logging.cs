using System.Diagnostics.Tracing;
using System.Runtime.CompilerServices;
using System.Text;

namespace WinRun.Agent.Services;

// MARK: - Log Level

/// <summary>
/// Log severity levels ordered by verbosity (debug is most verbose).
/// </summary>
public enum LogLevel
{
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

/// <summary>
/// Extension methods for <see cref="LogLevel"/>.
/// </summary>
public static class LogLevelExtensions
{
    /// <summary>Gets the display name for the log level.</summary>
    public static string Name(this LogLevel level) => level switch
    {
        LogLevel.Debug => "DEBUG",
        LogLevel.Info => "INFO",
        LogLevel.Warn => "WARN",
        LogLevel.Error => "ERROR",
        _ => "UNKNOWN",
    };

    /// <summary>Maps to ETW EventLevel.</summary>
    public static EventLevel ToEventLevel(this LogLevel level) => level switch
    {
        LogLevel.Debug => EventLevel.Verbose,
        LogLevel.Info => EventLevel.Informational,
        LogLevel.Warn => EventLevel.Warning,
        LogLevel.Error => EventLevel.Error,
        _ => EventLevel.Informational,
    };
}

// MARK: - Log Metadata

/// <summary>
/// Structured key-value metadata attached to log entries.
/// </summary>
public sealed class LogMetadata : Dictionary<string, object?>
{
    public LogMetadata() : base(StringComparer.OrdinalIgnoreCase) { }

    public LogMetadata(IDictionary<string, object?> dictionary)
        : base(dictionary, StringComparer.OrdinalIgnoreCase) { }

    /// <summary>
    /// Formats metadata as a key=value string for log output.
    /// </summary>
    public string Format() => Count == 0 ? string.Empty : string.Join(" ", this.Select(kv => $"{kv.Key}={FormatValue(kv.Value)}"));

    private static string FormatValue(object? value) => value switch
    {
        null => "null",
        string s => s,
        IEnumerable<object> enumerable => $"[{string.Join(", ", enumerable)}]",
        _ => value.ToString() ?? "null",
    };
}

// MARK: - Logger Interface

/// <summary>
/// Interface for logging implementations supporting structured metadata.
/// </summary>
public interface IAgentLogger
{
    /// <summary>
    /// Logs a message at the specified level with optional metadata.
    /// </summary>
    void Log(
        LogLevel level,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0);

    /// <summary>Gets or sets the minimum log level. Messages below this level are ignored.</summary>
    LogLevel MinimumLevel { get; set; }
}

// MARK: - Logger Extensions

/// <summary>
/// Convenience extension methods for <see cref="IAgentLogger"/>.
/// </summary>
public static class AgentLoggerExtensions
{
    public static void Debug(
        this IAgentLogger logger,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0) => logger.Log(LogLevel.Debug, message, metadata, file, function, line);

    public static void Info(
        this IAgentLogger logger,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0) => logger.Log(LogLevel.Info, message, metadata, file, function, line);

    public static void Warn(
        this IAgentLogger logger,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0) => logger.Log(LogLevel.Warn, message, metadata, file, function, line);

    public static void Error(
        this IAgentLogger logger,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0) => logger.Log(LogLevel.Error, message, metadata, file, function, line);

    /// <summary>
    /// Logs an exception with optional additional message.
    /// </summary>
    public static void Error(
        this IAgentLogger logger,
        Exception exception,
        string? message = null,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0)
    {
        var meta = metadata ?? [];
        meta["exception_type"] = exception.GetType().Name;
        meta["exception_message"] = exception.Message;
        if (exception.StackTrace != null)
        {
            meta["stack_trace"] = exception.StackTrace;
        }

        var msg = message ?? $"Exception: {exception.Message}";
        logger.Log(LogLevel.Error, msg, meta, file, function, line);
    }
}

// MARK: - Console Logger

/// <summary>
/// Logger that writes formatted messages to the console with timestamps.
/// Thread-safe via locking.
/// </summary>
public sealed class ConsoleLogger : IAgentLogger
{
    private static readonly object Gate = new();

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

        var fileName = Path.GetFileName(file);
        var timestamp = DateTime.UtcNow.ToString("o");

        var sb = new StringBuilder();
        _ = sb.Append($"[{timestamp}] [{level.Name()}] [{fileName}:{line}] {message}");

        if (metadata != null && metadata.Count > 0)
        {
            _ = sb.Append($" [{metadata.Format()}]");
        }

        lock (Gate)
        {
            var originalColor = Console.ForegroundColor;
            Console.ForegroundColor = level switch
            {
                LogLevel.Debug => ConsoleColor.Gray,
                LogLevel.Info => ConsoleColor.White,
                LogLevel.Warn => ConsoleColor.Yellow,
                LogLevel.Error => ConsoleColor.Red,
                _ => originalColor,
            };

            Console.WriteLine(sb.ToString());
            Console.ForegroundColor = originalColor;
        }
    }
}

// MARK: - File Logger

/// <summary>
/// Logger that writes to a file on disk with automatic rotation.
/// Thread-safe via locking.
/// </summary>
public sealed class FileLogger : IAgentLogger, IDisposable
{
    private readonly string _filePath;
    private readonly long _maxFileSizeBytes;
    private readonly int _maxRotatedFiles;
    private readonly object _gate = new();
    private StreamWriter? _writer;
    private bool _disposed;

    /// <summary>Default log directory: C:\ProgramData\WinRun\Logs</summary>
    public static string DefaultLogDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WinRun", "Logs");

    public LogLevel MinimumLevel { get; set; } = LogLevel.Debug;

    /// <summary>
    /// Creates a FileLogger that writes to the specified file.
    /// </summary>
    /// <param name="filePath">Path to the log file.</param>
    /// <param name="maxFileSizeBytes">Maximum file size before rotation (default 10MB).</param>
    /// <param name="maxRotatedFiles">Number of rotated files to keep (default 5).</param>
    public FileLogger(string filePath, long maxFileSizeBytes = 10_000_000, int maxRotatedFiles = 5)
    {
        _filePath = filePath;
        _maxFileSizeBytes = maxFileSizeBytes;
        _maxRotatedFiles = maxRotatedFiles;

        OpenFile();
    }

    public void Log(
        LogLevel level,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0)
    {
        if (level < MinimumLevel || _disposed)
        {
            return;
        }

        var fileName = Path.GetFileName(file);
        var timestamp = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss.fff");

        var sb = new StringBuilder();
        _ = sb.Append($"[{timestamp}] [{level.Name()}] [{fileName}:{line}] {message}");

        if (metadata != null && metadata.Count > 0)
        {
            _ = sb.Append($" [{metadata.Format()}]");
        }

        _ = sb.AppendLine();

        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            RotateIfNeeded();
            _writer?.Write(sb.ToString());
            _writer?.Flush();
        }
    }

    private void OpenFile()
    {
        var directory = Path.GetDirectoryName(_filePath);
        if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
        {
            _ = Directory.CreateDirectory(directory);
        }

        _writer = new StreamWriter(_filePath, append: true, Encoding.UTF8)
        {
            AutoFlush = false,
        };
    }

    private void RotateIfNeeded()
    {
        if (_writer == null)
        {
            return;
        }

        _writer.Flush();
        var fileInfo = new FileInfo(_filePath);
        if (!fileInfo.Exists || fileInfo.Length < _maxFileSizeBytes)
        {
            return;
        }

        // Close current file
        _writer.Dispose();
        _writer = null;

        // Rotate: rename current file with timestamp
        var timestamp = DateTime.UtcNow.ToString("yyyy-MM-dd-HHmmss");
        var directory = Path.GetDirectoryName(_filePath) ?? ".";
        var baseName = Path.GetFileNameWithoutExtension(_filePath);
        var extension = Path.GetExtension(_filePath);
        var rotatedPath = Path.Combine(directory, $"{baseName}.{timestamp}{extension}");

        try
        {
            File.Move(_filePath, rotatedPath);
        }
        catch
        {
            // If move fails, try to continue anyway
        }

        // Open new file
        OpenFile();

        // Cleanup old rotated logs
        CleanupOldLogs(directory, baseName, extension);
    }

    private void CleanupOldLogs(string directory, string baseName, string extension)
    {
        try
        {
            var pattern = $"{baseName}.*{extension}";
            var rotatedFiles = Directory.GetFiles(directory, pattern)
                .Where(f => f != _filePath)
                .OrderByDescending(File.GetCreationTimeUtc)
                .Skip(_maxRotatedFiles)
                .ToList();

            foreach (var oldFile in rotatedFiles)
            {
                try
                {
                    File.Delete(oldFile);
                }
                catch
                {
                    // Ignore deletion failures
                }
            }
        }
        catch
        {
            // Ignore cleanup failures
        }
    }

    /// <summary>Flushes buffered log data to disk.</summary>
    public void Flush()
    {
        lock (_gate)
        {
            _writer?.Flush();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _writer?.Dispose();
            _writer = null;
        }
    }
}

// MARK: - ETW Event Source

/// <summary>
/// ETW (Event Tracing for Windows) event source for WinRunAgent.
/// Events can be captured via Windows Event Viewer, perfview, or other ETW consumers.
/// </summary>
[EventSource(Name = "WinRun-Agent")]
public sealed class WinRunAgentEventSource : EventSource
{
    /// <summary>Singleton instance.</summary>
    public static readonly WinRunAgentEventSource Instance = new();

    private WinRunAgentEventSource() { }

    // Event IDs
    private const int DEBUG_EVENT_ID = 1;
    private const int INFO_EVENT_ID = 2;
    private const int WARN_EVENT_ID = 3;
    private const int ERROR_EVENT_ID = 4;

    [Event(DEBUG_EVENT_ID, Level = EventLevel.Verbose, Message = "{0}")]
    public void Debug(string message, string metadata) => WriteEvent(DEBUG_EVENT_ID, message, metadata);

    [Event(INFO_EVENT_ID, Level = EventLevel.Informational, Message = "{0}")]
    public void Info(string message, string metadata) => WriteEvent(INFO_EVENT_ID, message, metadata);

    [Event(WARN_EVENT_ID, Level = EventLevel.Warning, Message = "{0}")]
    public void Warn(string message, string metadata) => WriteEvent(WARN_EVENT_ID, message, metadata);

    [Event(ERROR_EVENT_ID, Level = EventLevel.Error, Message = "{0}")]
    public void Error(string message, string metadata) => WriteEvent(ERROR_EVENT_ID, message, metadata);
}

/// <summary>
/// Logger that writes to ETW (Event Tracing for Windows) via EventSource.
/// Events are visible in Windows Event Viewer and can be captured by perfview.
/// </summary>
public sealed class EtwLogger : IAgentLogger
{
    private readonly WinRunAgentEventSource _eventSource;

    public LogLevel MinimumLevel { get; set; } = LogLevel.Info;

    public EtwLogger() : this(WinRunAgentEventSource.Instance) { }

    public EtwLogger(WinRunAgentEventSource eventSource)
    {
        _eventSource = eventSource;
    }

    public void Log(
        LogLevel level,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0)
    {
        if (level < MinimumLevel || !_eventSource.IsEnabled())
        {
            return;
        }

        var metadataStr = metadata?.Format() ?? string.Empty;

        switch (level)
        {
            case LogLevel.Debug:
                _eventSource.Debug(message, metadataStr);
                break;
            case LogLevel.Info:
                _eventSource.Info(message, metadataStr);
                break;
            case LogLevel.Warn:
                _eventSource.Warn(message, metadataStr);
                break;
            case LogLevel.Error:
                _eventSource.Error(message, metadataStr);
                break;
            default:
                break;
        }
    }
}

// MARK: - Composite Logger

/// <summary>
/// Logger that dispatches to multiple underlying loggers.
/// </summary>
public sealed class CompositeLogger : IAgentLogger
{
    private readonly IAgentLogger[] _loggers;
    private LogLevel _minimumLevel = LogLevel.Debug;

    public CompositeLogger(params IAgentLogger[] loggers)
    {
        _loggers = loggers;
    }

    public CompositeLogger(IEnumerable<IAgentLogger> loggers)
    {
        _loggers = loggers.ToArray();
    }

    public LogLevel MinimumLevel
    {
        get => _minimumLevel;
        set
        {
            _minimumLevel = value;
            foreach (var logger in _loggers)
            {
                logger.MinimumLevel = value;
            }
        }
    }

    public void Log(
        LogLevel level,
        string message,
        LogMetadata? metadata = null,
        [CallerFilePath] string file = "",
        [CallerMemberName] string function = "",
        [CallerLineNumber] int line = 0)
    {
        if (level < _minimumLevel)
        {
            return;
        }

        foreach (var logger in _loggers)
        {
            logger.Log(level, message, metadata, file, function, line);
        }
    }
}

// MARK: - Logger Factory

/// <summary>
/// Factory for creating pre-configured loggers for WinRunAgent components.
/// </summary>
public static class LoggerFactory
{
    /// <summary>Default log directory.</summary>
    public static string DefaultLogDirectory => FileLogger.DefaultLogDirectory;

    /// <summary>
    /// Creates a logger for the WinRunAgent service.
    /// </summary>
    /// <param name="enableFile">Whether to write to file (default true).</param>
    /// <param name="enableEtw">Whether to write to ETW (default true).</param>
    /// <param name="enableConsole">Whether to write to console (default false for service).</param>
    /// <param name="minimumLevel">Minimum log level (default Info).</param>
    public static IAgentLogger CreateAgentLogger(
        bool enableFile = true,
        bool enableEtw = true,
        bool enableConsole = false,
        LogLevel minimumLevel = LogLevel.Info) => CreateLogger(
            logFileName: "WinRunAgent.log",
            enableFile: enableFile,
            enableEtw: enableEtw,
            enableConsole: enableConsole,
            minimumLevel: minimumLevel);

    /// <summary>
    /// Creates a development logger with console output enabled.
    /// </summary>
    public static IAgentLogger CreateDevelopmentLogger(LogLevel minimumLevel = LogLevel.Debug) => CreateLogger(
            logFileName: "WinRunAgent.log",
            enableFile: true,
            enableEtw: false,
            enableConsole: true,
            minimumLevel: minimumLevel);

    /// <summary>
    /// Creates a logger for a specific component.
    /// </summary>
    public static IAgentLogger CreateLogger(
        string logFileName,
        bool enableFile = true,
        bool enableEtw = true,
        bool enableConsole = false,
        LogLevel minimumLevel = LogLevel.Info)
    {
        var loggers = new List<IAgentLogger>();

        if (enableConsole)
        {
            loggers.Add(new ConsoleLogger { MinimumLevel = minimumLevel });
        }

        if (enableFile)
        {
            var filePath = Path.Combine(DefaultLogDirectory, logFileName);
            loggers.Add(new FileLogger(filePath) { MinimumLevel = minimumLevel });
        }

        if (enableEtw)
        {
            loggers.Add(new EtwLogger { MinimumLevel = minimumLevel });
        }

        return loggers.Count switch
        {
            0 => new ConsoleLogger { MinimumLevel = minimumLevel }, // Fallback
            1 => loggers[0],
            _ => new CompositeLogger(loggers) { MinimumLevel = minimumLevel },
        };
    }
}
