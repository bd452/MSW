namespace WinRun.Agent.Services;

/// <summary>
/// Result of a drag/drop operation.
/// </summary>
public sealed record DragDropResult(
    bool Success,
    string[] StagedPaths,
    string? ErrorMessage = null)
{
    public static DragDropResult Ok(string[] stagedPaths) => new(true, stagedPaths);
    public static DragDropResult Fail(string error) => new(false, [], error);
}

/// <summary>
/// Handles drag and drop file ingestion from the host (macOS) to guest (Windows).
/// Implements safe file staging to prevent path traversal and other security issues.
/// </summary>
public sealed class DragDropService : IDisposable
{
    private const string STAGING_DIRECTORY_NAME = "WinRunDragDrop";
    private const int MAX_FILE_SIZE = 512 * 1024 * 1024; // 512 MB per file limit
    private const long MAX_TOTAL_SIZE = 2L * 1024 * 1024 * 1024; // 2 GB total limit

    private readonly IAgentLogger _logger;
    private readonly object _lock = new();

    // Tracks active drag operations by window ID
    private readonly Dictionary<ulong, DragSession> _activeSessions = [];

    private bool _disposed;

    public DragDropService(IAgentLogger logger, string? stagingRoot = null)
    {
        _logger = logger;
        StagingRoot = stagingRoot ?? Path.Combine(Path.GetTempPath(), STAGING_DIRECTORY_NAME);
        EnsureStagingDirectory();
    }

    /// <summary>
    /// Gets the root staging directory path.
    /// </summary>
    public string StagingRoot { get; }

    /// <summary>
    /// Handles a drag/drop event from the host.
    /// </summary>
    public DragDropResult HandleDragDrop(DragDropMessage message) => message.EventType switch
    {
        DragDropEventType.Enter => HandleDragEnter(message),
        DragDropEventType.Move => HandleDragMove(message),
        DragDropEventType.Leave => HandleDragLeave(message),
        DragDropEventType.Drop => HandleDrop(message),
        _ => DragDropResult.Fail($"Unknown drag/drop event type: {message.EventType}")
    };

    /// <summary>
    /// Validates file paths before staging.
    /// </summary>
    public static bool ValidatePaths(DraggedFileInfo[] files, out string? error)
    {
        error = null;

        if (files.Length == 0)
        {
            error = "No files provided";
            return false;
        }

        foreach (var file in files)
        {
            // Validate host path is not empty
            if (string.IsNullOrWhiteSpace(file.HostPath))
            {
                error = "Empty host path provided";
                return false;
            }

            // Check for path traversal attempts
            if (file.HostPath.Contains("..") ||
                (file.GuestPath != null && file.GuestPath.Contains("..")))
            {
                error = "Path traversal detected in file paths";
                return false;
            }

            // Validate file size
            if (file.FileSize > MAX_FILE_SIZE)
            {
                error = $"File exceeds maximum size limit: {file.HostPath} ({file.FileSize} bytes)";
                return false;
            }
        }

        // Check total size
        var totalSize = files.Sum(f => (long)f.FileSize);
        if (totalSize > MAX_TOTAL_SIZE)
        {
            error = $"Total file size exceeds limit: {totalSize} bytes";
            return false;
        }

        return true;
    }

    /// <summary>
    /// Stages files to a secure location for the drop operation.
    /// </summary>
    public DragDropResult StageFiles(ulong windowId, DraggedFileInfo[] files)
    {
        if (!ValidatePaths(files, out var validationError))
        {
            _logger.Warn($"Path validation failed: {validationError}");
            return DragDropResult.Fail(validationError!);
        }

        lock (_lock)
        {
            // Create a unique staging directory for this operation
            var sessionId = Guid.NewGuid().ToString("N")[..8];
            var sessionDir = Path.Combine(StagingRoot, sessionId);

            try
            {
                _ = Directory.CreateDirectory(sessionDir);

                var stagedPaths = new List<string>();

                foreach (var file in files)
                {
                    var stagedPath = StageFile(sessionDir, file);
                    if (stagedPath == null)
                    {
                        // Cleanup on failure
                        CleanupSessionDirectory(sessionDir);
                        return DragDropResult.Fail($"Failed to stage file: {file.HostPath}");
                    }
                    stagedPaths.Add(stagedPath);
                }

                // Track the session
                _activeSessions[windowId] = new DragSession(
                    SessionId: sessionId,
                    WindowId: windowId,
                    StagingDirectory: sessionDir,
                    StagedFiles: [.. stagedPaths],
                    CreatedAt: DateTime.UtcNow);

                _logger.Info($"Staged {stagedPaths.Count} files for window {windowId} in {sessionDir}");
                return DragDropResult.Ok([.. stagedPaths]);
            }
            catch (Exception ex)
            {
                _logger.Error($"Failed to stage files for window {windowId}: {ex.Message}");
                CleanupSessionDirectory(sessionDir);
                return DragDropResult.Fail(ex.Message);
            }
        }
    }

    /// <summary>
    /// Gets the staged file paths for a window's active drag session.
    /// </summary>
    public string[]? GetStagedFiles(ulong windowId)
    {
        lock (_lock)
        {
            return _activeSessions.TryGetValue(windowId, out var session)
                ? session.StagedFiles
                : null;
        }
    }

    /// <summary>
    /// Commits the drop operation, making staged files permanent.
    /// </summary>
    public DragDropResult CommitDrop(ulong windowId, string? destinationDirectory = null)
    {
        lock (_lock)
        {
            if (!_activeSessions.TryGetValue(windowId, out var session))
            {
                return DragDropResult.Fail("No active drag session for window");
            }

            try
            {
                string[] finalPaths;

                if (destinationDirectory != null)
                {
                    // Move files to final destination
                    _ = Directory.CreateDirectory(destinationDirectory);
                    finalPaths = new string[session.StagedFiles.Length];

                    for (var i = 0; i < session.StagedFiles.Length; i++)
                    {
                        var stagedPath = session.StagedFiles[i];
                        var fileName = Path.GetFileName(stagedPath);
                        var destPath = Path.Combine(destinationDirectory, fileName);

                        // Handle name conflicts
                        destPath = GetUniqueDestinationPath(destPath);

                        if (File.Exists(stagedPath))
                        {
                            File.Move(stagedPath, destPath);
                        }
                        else if (Directory.Exists(stagedPath))
                        {
                            MoveDirectory(stagedPath, destPath);
                        }

                        finalPaths[i] = destPath;
                    }

                    // Cleanup staging directory
                    CleanupSessionDirectory(session.StagingDirectory);
                }
                else
                {
                    // Keep files in staging directory
                    finalPaths = session.StagedFiles;
                }

                _ = _activeSessions.Remove(windowId);
                _logger.Info($"Committed drop for window {windowId}: {finalPaths.Length} files");
                return DragDropResult.Ok(finalPaths);
            }
            catch (Exception ex)
            {
                _logger.Error($"Failed to commit drop for window {windowId}: {ex.Message}");
                return DragDropResult.Fail(ex.Message);
            }
        }
    }

    /// <summary>
    /// Cancels a drag operation and cleans up staged files.
    /// </summary>
    public void CancelDrag(ulong windowId)
    {
        lock (_lock)
        {
            if (_activeSessions.TryGetValue(windowId, out var session))
            {
                CleanupSessionDirectory(session.StagingDirectory);
                _ = _activeSessions.Remove(windowId);
                _logger.Debug($"Cancelled drag session for window {windowId}");
            }
        }
    }

    /// <summary>
    /// Cleans up stale staging directories older than the specified age.
    /// </summary>
    public void CleanupStaleSessions(TimeSpan maxAge)
    {
        lock (_lock)
        {
            var cutoff = DateTime.UtcNow - maxAge;
            var staleWindows = _activeSessions
                .Where(kvp => kvp.Value.CreatedAt < cutoff)
                .Select(kvp => kvp.Key)
                .ToList();

            foreach (var windowId in staleWindows)
            {
                if (_activeSessions.TryGetValue(windowId, out var session))
                {
                    CleanupSessionDirectory(session.StagingDirectory);
                    _ = _activeSessions.Remove(windowId);
                    _logger.Debug($"Cleaned up stale drag session for window {windowId}");
                }
            }

            // Also cleanup orphaned directories
            try
            {
                if (Directory.Exists(StagingRoot))
                {
                    foreach (var dir in Directory.GetDirectories(StagingRoot))
                    {
                        var dirInfo = new DirectoryInfo(dir);
                        if (dirInfo.CreationTimeUtc < cutoff)
                        {
                            CleanupSessionDirectory(dir);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                _logger.Warn($"Error cleaning orphaned staging directories: {ex.Message}");
            }
        }
    }

    private DragDropResult HandleDragEnter(DragDropMessage message)
    {
        _logger.Debug($"Drag enter window {message.WindowId}: {message.Files.Length} files");

        // Validate and pre-stage files
        return message.Files.Length == 0 ? DragDropResult.Ok([]) : StageFiles(message.WindowId, message.Files);
    }

    private DragDropResult HandleDragMove(DragDropMessage message)
    {
        // Just update position tracking if needed
        _logger.Debug($"Drag move window {message.WindowId}: ({message.X}, {message.Y})");
        return DragDropResult.Ok([]);
    }

    private DragDropResult HandleDragLeave(DragDropMessage message)
    {
        _logger.Debug($"Drag leave window {message.WindowId}");
        CancelDrag(message.WindowId);
        return DragDropResult.Ok([]);
    }

    private DragDropResult HandleDrop(DragDropMessage message)
    {
        _logger.Info($"Drop on window {message.WindowId} at ({message.X}, {message.Y})");

        // If files weren't pre-staged on enter, stage them now
        if (!_activeSessions.ContainsKey(message.WindowId) && message.Files.Length > 0)
        {
            var stageResult = StageFiles(message.WindowId, message.Files);
            if (!stageResult.Success)
            {
                return stageResult;
            }
        }

        // Commit the drop (files stay in staging for the app to access)
        return CommitDrop(message.WindowId);
    }

    private string? StageFile(string sessionDir, DraggedFileInfo file)
    {
        try
        {
            // Use the guest path filename if available, otherwise extract from host path
            var fileName = !string.IsNullOrEmpty(file.GuestPath)
                ? Path.GetFileName(file.GuestPath)
                : Path.GetFileName(file.HostPath);

            // Sanitize filename
            fileName = SanitizeFileName(fileName);
            if (string.IsNullOrEmpty(fileName))
            {
                fileName = $"file_{Guid.NewGuid():N}";
            }

            var stagedPath = Path.Combine(sessionDir, fileName);

            if (file.IsDirectory)
            {
                // Create placeholder directory
                _ = Directory.CreateDirectory(stagedPath);
                _logger.Debug($"Created staging directory: {stagedPath}");
            }
            else
            {
                // Create placeholder file
                // Note: In production, the actual file content would be transferred
                // via VirtioFS or Spice file transfer channel. Here we create
                // a marker file that the VirtioFS mount can be used to access.
                File.WriteAllText(stagedPath + ".hostpath", file.HostPath);

                // If the file already exists at the mapped path, copy it
                var mappedPath = MapHostPathToGuest(file.HostPath);
                if (!string.IsNullOrEmpty(mappedPath) && File.Exists(mappedPath))
                {
                    File.Copy(mappedPath, stagedPath, overwrite: true);
                    _logger.Debug($"Copied from VirtioFS: {mappedPath} -> {stagedPath}");
                }
                else
                {
                    // Create empty placeholder; file content will be available
                    // when VirtioFS mount is active
                    using var fs = File.Create(stagedPath);
                    _logger.Debug($"Created staging placeholder: {stagedPath}");
                }
            }

            return stagedPath;
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to stage file {file.HostPath}: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Maps a macOS host path to the equivalent Windows guest path via VirtioFS.
    /// The host mounts /Users as Z:\ in the guest.
    /// </summary>
    private static string? MapHostPathToGuest(string hostPath)
    {
        // macOS paths starting with /Users/ map to Z:\
        if (hostPath.StartsWith("/Users/", StringComparison.Ordinal))
        {
            var relativePath = hostPath[7..]; // Remove "/Users/"
            return Path.Combine("Z:\\", relativePath.Replace('/', '\\'));
        }

        // Paths under /tmp may be mapped if configured
        if (hostPath.StartsWith("/tmp/", StringComparison.Ordinal))
        {
            var relativePath = hostPath[5..];
            return Path.Combine("Z:\\tmp", relativePath.Replace('/', '\\'));
        }

        return null;
    }

    private static string SanitizeFileName(string fileName)
    {
        // Remove invalid characters
        var invalid = Path.GetInvalidFileNameChars();
        var sanitized = new string([.. fileName.Where(c => !invalid.Contains(c))]);

        // Limit length
        if (sanitized.Length > 200)
        {
            var ext = Path.GetExtension(sanitized);
            var name = Path.GetFileNameWithoutExtension(sanitized);
            sanitized = name[..Math.Min(name.Length, 200 - ext.Length)] + ext;
        }

        return sanitized;
    }

    private static string GetUniqueDestinationPath(string destPath)
    {
        if (!File.Exists(destPath) && !Directory.Exists(destPath))
        {
            return destPath;
        }

        var dir = Path.GetDirectoryName(destPath) ?? string.Empty;
        var name = Path.GetFileNameWithoutExtension(destPath);
        var ext = Path.GetExtension(destPath);

        for (var i = 1; i < 1000; i++)
        {
            var newPath = Path.Combine(dir, $"{name} ({i}){ext}");
            if (!File.Exists(newPath) && !Directory.Exists(newPath))
            {
                return newPath;
            }
        }

        // Fallback with GUID
        return Path.Combine(dir, $"{name}_{Guid.NewGuid():N}{ext}");
    }

    private static void MoveDirectory(string source, string destination)
    {
        _ = Directory.CreateDirectory(destination);

        foreach (var file in Directory.GetFiles(source))
        {
            var destFile = Path.Combine(destination, Path.GetFileName(file));
            File.Move(file, destFile);
        }

        foreach (var dir in Directory.GetDirectories(source))
        {
            var destDir = Path.Combine(destination, Path.GetFileName(dir));
            MoveDirectory(dir, destDir);
        }

        Directory.Delete(source, false);
    }

    private void EnsureStagingDirectory()
    {
        try
        {
            if (!Directory.Exists(StagingRoot))
            {
                _ = Directory.CreateDirectory(StagingRoot);
                _logger.Debug($"Created staging root: {StagingRoot}");
            }
        }
        catch (Exception ex)
        {
            _logger.Error($"Failed to create staging directory: {ex.Message}");
        }
    }

    private void CleanupSessionDirectory(string sessionDir)
    {
        try
        {
            if (Directory.Exists(sessionDir))
            {
                Directory.Delete(sessionDir, recursive: true);
            }
        }
        catch (Exception ex)
        {
            _logger.Warn($"Failed to cleanup session directory {sessionDir}: {ex.Message}");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        lock (_lock)
        {
            // Cleanup all active sessions
            foreach (var session in _activeSessions.Values)
            {
                CleanupSessionDirectory(session.StagingDirectory);
            }
            _activeSessions.Clear();
        }

        _disposed = true;
    }
}

/// <summary>
/// Represents an active drag session for a window.
/// </summary>
internal sealed record DragSession(
    string SessionId,
    ulong WindowId,
    string StagingDirectory,
    string[] StagedFiles,
    DateTime CreatedAt);
