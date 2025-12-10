using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;

namespace WinRun.Agent.Services;

/// <summary>
/// Result of a program launch attempt.
/// </summary>
public readonly record struct LaunchResult
{
    public bool Success { get; init; }
    public int? ProcessId { get; init; }
    public string? ErrorMessage { get; init; }
    public LaunchErrorCode ErrorCode { get; init; }

    public static LaunchResult Succeeded(int processId) => new()
    {
        Success = true,
        ProcessId = processId,
        ErrorCode = LaunchErrorCode.None
    };

    public static LaunchResult Failed(LaunchErrorCode code, string message) => new()
    {
        Success = false,
        ErrorMessage = message,
        ErrorCode = code
    };

    public static LaunchResult AlreadyLaunched(int processId) => new()
    {
        Success = true,
        ProcessId = processId,
        ErrorCode = LaunchErrorCode.AlreadyLaunched
    };
}

/// <summary>
/// Error codes for program launch failures.
/// </summary>
public enum LaunchErrorCode
{
    None = 0,
    AlreadyLaunched = 1,
    ExecutableNotFound = 2,
    WorkingDirectoryNotFound = 3,
    AccessDenied = 4,
    InvalidExecutable = 5,
    ProcessStartFailed = 6
}

/// <summary>
/// Launches Windows processes with full support for arguments, environment variables,
/// and working directories. Implements idempotency via message ID tracking.
/// </summary>
public sealed class ProgramLauncher : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly ConcurrentDictionary<uint, LaunchedProcessInfo> _launchedProcesses = new();
    private readonly ConcurrentDictionary<uint, LaunchResult> _messageIdCache = new();
    private readonly Timer _cleanupTimer;
    private bool _disposed;

    /// <summary>
    /// Maximum age for message ID cache entries before cleanup.
    /// </summary>
    private static readonly TimeSpan MessageIdCacheExpiry = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Interval for cleaning up stale cache entries.
    /// </summary>
    private static readonly TimeSpan CleanupInterval = TimeSpan.FromMinutes(1);

    public ProgramLauncher(IAgentLogger logger)
    {
        _logger = logger;
        _cleanupTimer = new Timer(CleanupStaleEntries, null, CleanupInterval, CleanupInterval);
    }

    /// <summary>
    /// Launches a program from a LaunchProgramMessage. Idempotent based on MessageId.
    /// </summary>
    public async Task<LaunchResult> LaunchAsync(LaunchProgramMessage message, CancellationToken token)
    {
        // Idempotency check: if we've already processed this message, return cached result
        if (_messageIdCache.TryGetValue(message.MessageId, out var cachedResult))
        {
            _logger.Debug($"Duplicate launch request for MessageId {message.MessageId}, returning cached result");
            return cachedResult with { ErrorCode = LaunchErrorCode.AlreadyLaunched };
        }

        var result = await LaunchCoreAsync(
            message.Path,
            message.Arguments,
            message.WorkingDirectory,
            message.Environment,
            token);

        // Cache the result for idempotency
        _ = _messageIdCache.TryAdd(message.MessageId, result);

        return result;
    }

    /// <summary>
    /// Launches a program with the specified parameters.
    /// </summary>
    public async Task<LaunchResult> LaunchAsync(
        string path,
        string[]? arguments = null,
        string? workingDirectory = null,
        Dictionary<string, string>? environment = null,
        CancellationToken token = default) => await LaunchCoreAsync(path, arguments ?? [], workingDirectory, environment, token);

    /// <summary>
    /// Gets information about a launched process by its process ID.
    /// </summary>
    public LaunchedProcessInfo? GetProcessInfo(int processId) => _launchedProcesses.Values.FirstOrDefault(p => p.ProcessId == processId);

    /// <summary>
    /// Gets all currently tracked processes.
    /// </summary>
    public IReadOnlyCollection<LaunchedProcessInfo> GetTrackedProcesses() => _launchedProcesses.Values.Where(p => !p.HasExited).ToList();

    private async Task<LaunchResult> LaunchCoreAsync(
        string path,
        string[] arguments,
        string? workingDirectory,
        Dictionary<string, string>? environment,
        CancellationToken token)
    {
        // Validate executable path
        var validationResult = ValidateExecutablePath(path);
        if (!validationResult.Success)
        {
            return validationResult;
        }

        // Validate working directory if specified
        if (!string.IsNullOrEmpty(workingDirectory))
        {
            if (!Directory.Exists(workingDirectory))
            {
                var msg = $"Working directory not found: {workingDirectory}";
                _logger.Error(msg);
                return LaunchResult.Failed(LaunchErrorCode.WorkingDirectoryNotFound, msg);
            }
        }

        // Build process start info
        var psi = new ProcessStartInfo
        {
            FileName = path,
            UseShellExecute = false,
            CreateNoWindow = false,
            RedirectStandardOutput = false,
            RedirectStandardError = false,
            RedirectStandardInput = false
        };

        // Set working directory
        if (!string.IsNullOrEmpty(workingDirectory))
        {
            psi.WorkingDirectory = workingDirectory;
        }
        else
        {
            // Default to executable's directory
            var exeDir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(exeDir) && Directory.Exists(exeDir))
            {
                psi.WorkingDirectory = exeDir;
            }
        }

        // Add arguments using proper escaping
        foreach (var arg in arguments)
        {
            psi.ArgumentList.Add(arg);
        }

        // Merge environment variables
        if (environment != null && environment.Count > 0)
        {
            // First copy existing environment (UseShellExecute=false means we need to populate it)
            foreach (var (key, value) in environment)
            {
                psi.Environment[key] = value;
            }
        }

        return await StartProcessAsync(psi, token);
    }

    private LaunchResult ValidateExecutablePath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            const string msg = "Executable path cannot be empty";
            _logger.Error(msg);
            return LaunchResult.Failed(LaunchErrorCode.InvalidExecutable, msg);
        }

        // Check if file exists
        if (!File.Exists(path))
        {
            // Try resolving via PATH environment variable for shell commands
            var resolvedPath = ResolveFromPath(path);
            if (resolvedPath == null)
            {
                var msg = $"Executable not found: {path}";
                _logger.Error(msg);
                return LaunchResult.Failed(LaunchErrorCode.ExecutableNotFound, msg);
            }
        }

        return LaunchResult.Succeeded(0); // Placeholder - actual PID set after launch
    }

    private static string? ResolveFromPath(string executable)
    {
        // If it's already an absolute path or has an extension, don't search PATH
        if (Path.IsPathRooted(executable) || Path.HasExtension(executable))
        {
            return null;
        }

        var pathEnv = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(pathEnv))
        {
            return null;
        }

        var extensions = new[] { ".exe", ".cmd", ".bat", ".com" };
        var pathDirs = pathEnv.Split(Path.PathSeparator);

        foreach (var dir in pathDirs)
        {
            foreach (var ext in extensions)
            {
                var fullPath = Path.Combine(dir, executable + ext);
                if (File.Exists(fullPath))
                {
                    return fullPath;
                }
            }
        }

        return null;
    }

    private async Task<LaunchResult> StartProcessAsync(ProcessStartInfo psi, CancellationToken token)
    {
        try
        {
            var process = new Process
            {
                StartInfo = psi,
                EnableRaisingEvents = true
            };

            var launchTime = DateTime.UtcNow;

            process.Exited += (_, _) =>
            {
                try
                {
                    var exitCode = process.ExitCode;
                    _logger.Info($"Process {psi.FileName} (PID {process.Id}) exited with code {exitCode}");

                    // Update tracked process info
                    if (_launchedProcesses.TryGetValue((uint)process.Id, out var info))
                    {
                        info.MarkExited(exitCode);
                    }
                }
                catch (InvalidOperationException)
                {
                    // Process already disposed
                }
            };

            _logger.Info($"Launching: {psi.FileName} {string.Join(" ", psi.ArgumentList)}");

            if (!process.Start())
            {
                const string msg = "Process.Start() returned false";
                _logger.Error(msg);
                return LaunchResult.Failed(LaunchErrorCode.ProcessStartFailed, msg);
            }

            var processId = process.Id;

            // Track the launched process
            var processInfo = new LaunchedProcessInfo(
                processId,
                psi.FileName,
                [.. psi.ArgumentList],
                psi.WorkingDirectory,
                launchTime);

            _ = _launchedProcesses.TryAdd((uint)processId, processInfo);

            _logger.Info($"Successfully launched {psi.FileName} with PID {processId}");

            // Allow cancellation to kill the process
            if (token.CanBeCanceled)
            {
                _ = token.Register(() =>
                {
                    try
                    {
                        if (!process.HasExited)
                        {
                            _logger.Info($"Cancellation requested, killing process {processId}");
                            process.Kill(entireProcessTree: true);
                        }
                    }
                    catch (Exception ex)
                    {
                        _logger.Warn($"Failed to kill process on cancellation: {ex.Message}");
                    }
                });
            }

            await Task.CompletedTask;
            return LaunchResult.Succeeded(processId);
        }
        catch (Win32Exception ex)
        {
            var errorCode = ex.NativeErrorCode switch
            {
                2 => LaunchErrorCode.ExecutableNotFound, // ERROR_FILE_NOT_FOUND
                3 => LaunchErrorCode.WorkingDirectoryNotFound, // ERROR_PATH_NOT_FOUND
                5 => LaunchErrorCode.AccessDenied, // ERROR_ACCESS_DENIED
                193 => LaunchErrorCode.InvalidExecutable, // ERROR_BAD_EXE_FORMAT
                _ => LaunchErrorCode.ProcessStartFailed
            };

            var msg = $"Failed to start process: {ex.Message} (Win32 error {ex.NativeErrorCode})";
            _logger.Error(msg);
            return LaunchResult.Failed(errorCode, msg);
        }
        catch (Exception ex)
        {
            var msg = $"Unexpected error starting process: {ex.Message}";
            _logger.Error(msg);
            return LaunchResult.Failed(LaunchErrorCode.ProcessStartFailed, msg);
        }
    }

    private void CleanupStaleEntries(object? state)
    {
        var cutoff = DateTime.UtcNow - MessageIdCacheExpiry;
        var staleIds = new List<uint>();

        // Find stale message IDs (those older than expiry)
        // Note: We can't easily determine age from LaunchResult, so we use a simpler approach:
        // Clear all entries periodically, relying on the short window for idempotency
        if (_messageIdCache.Count > 1000)
        {
            _messageIdCache.Clear();
            _logger.Debug("Cleared message ID cache (exceeded 1000 entries)");
        }

        // Clean up exited processes that have been tracked for a while
        var exitedProcesses = _launchedProcesses
            .Where(kvp => kvp.Value.HasExited && kvp.Value.ExitTime.HasValue &&
                          DateTime.UtcNow - kvp.Value.ExitTime.Value > TimeSpan.FromMinutes(10))
            .Select(kvp => kvp.Key)
            .ToList();

        foreach (var pid in exitedProcesses)
        {
            _ = _launchedProcesses.TryRemove(pid, out _);
        }

        if (exitedProcesses.Count > 0)
        {
            _logger.Debug($"Cleaned up {exitedProcesses.Count} exited process entries");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _cleanupTimer.Dispose();
        _disposed = true;
    }
}

/// <summary>
/// Information about a launched process.
/// </summary>
public sealed class LaunchedProcessInfo
{
    public int ProcessId { get; }
    public string ExecutablePath { get; }
    public string[] Arguments { get; }
    public string? WorkingDirectory { get; }
    public DateTime LaunchTime { get; }
    public DateTime? ExitTime { get; private set; }
    public int? ExitCode { get; private set; }
    public bool HasExited => ExitTime.HasValue;

    public LaunchedProcessInfo(
        int processId,
        string executablePath,
        string[] arguments,
        string? workingDirectory,
        DateTime launchTime)
    {
        ProcessId = processId;
        ExecutablePath = executablePath;
        Arguments = arguments;
        WorkingDirectory = workingDirectory;
        LaunchTime = launchTime;
    }

    internal void MarkExited(int exitCode)
    {
        ExitCode = exitCode;
        ExitTime = DateTime.UtcNow;
    }
}
