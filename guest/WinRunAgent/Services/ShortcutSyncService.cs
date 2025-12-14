using System.Runtime.InteropServices;

namespace WinRun.Agent.Services;

/// <summary>
/// Monitors Windows shortcut locations and detects new/changed shortcuts
/// to notify the host for launcher generation.
/// </summary>
public sealed class ShortcutSyncService : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly Action<ShortcutDetectedMessage> _onShortcutDetected;
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly HashSet<string> _knownShortcuts = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _gate = new();
    private bool _disposed;
    private bool _isRunning;

    /// <summary>
    /// Standard locations to monitor for shortcuts.
    /// </summary>
    private static readonly string[] ShortcutLocations =
    [
        Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
        Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
        Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory),
        Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
        Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms),
        Environment.GetFolderPath(Environment.SpecialFolder.Programs)
    ];

    public ShortcutSyncService(
        IAgentLogger logger,
        IconExtractionService iconService,
        Action<ShortcutDetectedMessage> onShortcutDetected)
    {
        _logger = logger;
        IconService = iconService;
        _onShortcutDetected = onShortcutDetected;
    }

    /// <summary>
    /// Gets the icon extraction service for proactive icon fetching.
    /// </summary>
    public IconExtractionService IconService { get; }

    /// <summary>
    /// Gets the list of known shortcut paths.
    /// </summary>
    public IReadOnlyCollection<string> KnownShortcuts
    {
        get
        {
            lock (_gate)
            {
                return [.. _knownShortcuts];
            }
        }
    }

    /// <summary>
    /// Starts monitoring shortcut locations and performs initial scan.
    /// </summary>
    public void Start()
    {
        lock (_gate)
        {
            if (_isRunning)
            {
                return;
            }

            _isRunning = true;
        }

        _logger.Info("Starting shortcut sync service");

        // Perform initial scan
        ScanExistingShortcuts();

        // Set up file system watchers
        SetupWatchers();

        _logger.Info($"Monitoring {_watchers.Count} shortcut locations");
    }

    /// <summary>
    /// Stops monitoring shortcut locations.
    /// </summary>
    public void Stop()
    {
        lock (_gate)
        {
            if (!_isRunning)
            {
                return;
            }

            _isRunning = false;

            foreach (var watcher in _watchers)
            {
                watcher.EnableRaisingEvents = false;
                watcher.Dispose();
            }

            _watchers.Clear();
        }

        _logger.Info("Shortcut sync service stopped");
    }

    /// <summary>
    /// Manually triggers a rescan of all shortcut locations.
    /// </summary>
    public void Rescan()
    {
        _logger.Debug("Manual shortcut rescan requested");
        ScanExistingShortcuts();
    }

    /// <summary>
    /// Parses a shortcut file and returns its information, or null if invalid.
    /// </summary>
    public ShortcutInfo? ParseShortcut(string shortcutPath)
    {
        if (!File.Exists(shortcutPath))
        {
            return null;
        }

        try
        {
            var shellLink = (IShellLink)new ShellLink();
            var persistFile = (IPersistFile)shellLink;

            persistFile.Load(shortcutPath, 0);
            shellLink.Resolve(0, SLR.SLR_NO_UI | SLR.SLR_NOSEARCH);

            // Get target path
            var targetPath = new char[260];
            shellLink.GetPath(targetPath, targetPath.Length, out _, SLGP.SLGP_RAWPATH);
            var target = new string(targetPath).TrimEnd('\0');

            if (string.IsNullOrWhiteSpace(target))
            {
                return null;
            }

            // Get description (often used as display name)
            var description = new char[260];
            shellLink.GetDescription(description, description.Length);
            var displayName = new string(description).TrimEnd('\0');

            // Get icon location
            var iconPath = new char[260];
            shellLink.GetIconLocation(iconPath, iconPath.Length, out var iconIndex);
            var icon = new string(iconPath).TrimEnd('\0');

            // Get arguments
            var arguments = new char[1024];
            shellLink.GetArguments(arguments, arguments.Length);
            var args = new string(arguments).TrimEnd('\0');

            // Get working directory
            var workingDir = new char[260];
            shellLink.GetWorkingDirectory(workingDir, workingDir.Length);
            var workDir = new string(workingDir).TrimEnd('\0');

            // Use filename as display name if description is empty
            if (string.IsNullOrWhiteSpace(displayName))
            {
                displayName = Path.GetFileNameWithoutExtension(shortcutPath);
            }

            return new ShortcutInfo
            {
                ShortcutPath = shortcutPath,
                TargetPath = target,
                DisplayName = displayName,
                IconPath = string.IsNullOrWhiteSpace(icon) ? target : icon,
                IconIndex = iconIndex,
                Arguments = string.IsNullOrWhiteSpace(args) ? null : args,
                WorkingDirectory = string.IsNullOrWhiteSpace(workDir) ? null : workDir
            };
        }
        catch (Exception ex)
        {
            _logger.Debug($"Failed to parse shortcut {shortcutPath}: {ex.Message}");
            return null;
        }
    }

    private void ScanExistingShortcuts()
    {
        var scannedCount = 0;
        var newCount = 0;

        foreach (var location in ShortcutLocations)
        {
            if (string.IsNullOrEmpty(location) || !Directory.Exists(location))
            {
                continue;
            }

            try
            {
                var shortcuts = Directory.GetFiles(location, "*.lnk", SearchOption.AllDirectories);
                foreach (var shortcut in shortcuts)
                {
                    scannedCount++;
                    if (ProcessShortcut(shortcut, isNew: false))
                    {
                        newCount++;
                    }
                }
            }
            catch (Exception ex)
            {
                _logger.Warn($"Error scanning {location}: {ex.Message}");
            }
        }

        _logger.Debug($"Scanned {scannedCount} shortcuts, {newCount} new");
    }

    private void SetupWatchers()
    {
        foreach (var location in ShortcutLocations)
        {
            if (string.IsNullOrEmpty(location) || !Directory.Exists(location))
            {
                continue;
            }

            try
            {
                var watcher = new FileSystemWatcher(location)
                {
                    Filter = "*.lnk",
                    IncludeSubdirectories = true,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.CreationTime
                };

                watcher.Created += OnShortcutCreated;
                watcher.Changed += OnShortcutChanged;
                watcher.Renamed += OnShortcutRenamed;
                watcher.Error += OnWatcherError;

                watcher.EnableRaisingEvents = true;
                _watchers.Add(watcher);

                _logger.Debug($"Watching: {location}");
            }
            catch (Exception ex)
            {
                _logger.Warn($"Failed to watch {location}: {ex.Message}");
            }
        }
    }

    private void OnShortcutCreated(object sender, FileSystemEventArgs e) => ProcessShortcutAsync(e.FullPath, isNew: true);

    private void OnShortcutChanged(object sender, FileSystemEventArgs e) => ProcessShortcutAsync(e.FullPath, isNew: false);

    private void OnShortcutRenamed(object sender, RenamedEventArgs e)
    {
        // Remove old path from known shortcuts
        lock (_gate)
        {
            _ = _knownShortcuts.Remove(e.OldFullPath);
        }

        // Process new path
        ProcessShortcutAsync(e.FullPath, isNew: true);
    }

    private void OnWatcherError(object sender, ErrorEventArgs e) => _logger.Warn($"FileSystemWatcher error: {e.GetException().Message}");

    private void ProcessShortcutAsync(string path, bool isNew) =>
        // Process on thread pool to avoid blocking file system events
        ThreadPool.QueueUserWorkItem(_ =>
        {
            // Small delay to ensure file is fully written
            Thread.Sleep(100);
            _ = ProcessShortcut(path, isNew);
        });

    private bool ProcessShortcut(string path, bool isNew)
    {
        bool isNewShortcut;
        lock (_gate)
        {
            if (!_isRunning)
            {
                return false;
            }

            isNewShortcut = _knownShortcuts.Add(path);
        }

        // Only notify for truly new shortcuts or if explicitly marked as new
        if (!isNewShortcut && !isNew)
        {
            return false;
        }

        var info = ParseShortcut(path);
        if (info == null)
        {
            return false;
        }

        // Filter out non-executable shortcuts
        if (!IsExecutableTarget(info.TargetPath))
        {
            _logger.Debug($"Skipping non-executable shortcut: {info.TargetPath}");
            return false;
        }

        _logger.Debug($"Detected shortcut: {info.DisplayName} -> {info.TargetPath}");

        // Create notification message with full shortcut info
        var message = SpiceMessageSerializer.CreateShortcutMessage(info, isNew: isNewShortcut);

        try
        {
            _onShortcutDetected(message);
        }
        catch (Exception ex)
        {
            _logger.Error($"Error notifying shortcut detection: {ex.Message}");
        }

        return isNewShortcut;
    }

    private static bool IsExecutableTarget(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return false;
        }

        var extension = Path.GetExtension(path);
        return extension.Equals(".exe", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".msc", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".bat", StringComparison.OrdinalIgnoreCase);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        Stop();
        _disposed = true;
    }

    // ========================================================================
    // P/Invoke declarations (reused from IconExtractionService)
    // ========================================================================

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink
    {
    }

    [ComImport]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLink
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszFile, int cch, out WIN32_FIND_DATA pfd, SLGP fFlags);
        void GetIDList(out nint ppidl);
        void SetIDList(nint pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out ushort pwHotkey);
        void SetHotkey(ushort wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] char[] pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(nint hwnd, SLR fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport]
    [Guid("0000010B-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        [PreserveSig]
        int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [Flags]
    private enum SLR : uint
    {
        SLR_NO_UI = 0x0001,
        SLR_NOUPDATE = 0x0008,
        SLR_NOSEARCH = 0x0010,
        SLR_NOTRACK = 0x0020,
        SLR_NOLINKINFO = 0x0040,
        SLR_INVOKE_MSI = 0x0080
    }

    private enum SLGP : uint
    {
        SLGP_SHORTPATH = 0x0001,
        SLGP_UNCPRIORITY = 0x0002,
        SLGP_RAWPATH = 0x0004
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WIN32_FIND_DATA
    {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string cAlternateFileName;
    }
}

/// <summary>
/// Information extracted from a Windows shortcut (.lnk) file.
/// </summary>
public sealed class ShortcutInfo
{
    public required string ShortcutPath { get; init; }
    public required string TargetPath { get; init; }
    public required string DisplayName { get; init; }
    public required string IconPath { get; init; }
    public int IconIndex { get; init; }
    public string? Arguments { get; init; }
    public string? WorkingDirectory { get; init; }
}

