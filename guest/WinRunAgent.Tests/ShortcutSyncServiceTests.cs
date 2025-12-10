using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class ShortcutSyncServiceTests : IDisposable
{
    private readonly TestLogger _logger = new();
    private readonly string _testCacheDir;
    private readonly IconExtractionService _iconService;
    private readonly List<ShortcutDetectedMessage> _detectedShortcuts = [];
    private readonly ShortcutSyncService _service;

    public ShortcutSyncServiceTests()
    {
        _testCacheDir = Path.Combine(Path.GetTempPath(), $"ShortcutSyncTest_{Guid.NewGuid():N}");
        _iconService = new IconExtractionService(_logger, _testCacheDir, TimeSpan.FromHours(1));
        _service = new ShortcutSyncService(_logger, _iconService, _detectedShortcuts.Add);
    }

    public void Dispose()
    {
        _service.Dispose();
        _iconService.Dispose();

        if (Directory.Exists(_testCacheDir))
        {
            try
            {
                Directory.Delete(_testCacheDir, recursive: true);
            }
            catch
            {
                // Ignore cleanup failures
            }
        }
    }

    [Fact]
    public void Constructor_DoesNotStartMonitoring() =>
        // Service should not auto-start
        Assert.Empty(_service.KnownShortcuts);

    [Fact]
    public void Start_CanBeCalledMultipleTimes()
    {
        // Should not throw
        _service.Start();
        _service.Start();
        _service.Stop();
    }

    [Fact]
    public void Stop_CanBeCalledMultipleTimes()
    {
        _service.Start();
        _service.Stop();
        _service.Stop(); // Should not throw
    }

    [Fact]
    public void Stop_CanBeCalledWithoutStart() =>
        // Should not throw
        _service.Stop();

    [Fact]
    public void ParseShortcut_NonExistentFile_ReturnsNull()
    {
        var result = _service.ParseShortcut(@"C:\NonExistent\Path\shortcut.lnk");

        Assert.Null(result);
    }

    [Fact]
    public void ParseShortcut_InvalidPath_ReturnsNull()
    {
        var result = _service.ParseShortcut("");

        Assert.Null(result);
    }

    [Fact]
    public void KnownShortcuts_InitiallyEmpty() => Assert.Empty(_service.KnownShortcuts);

    [Fact]
    public void Rescan_WithoutStart_DoesNotThrow() =>
        // Rescan should be safe to call even when not started
        _service.Rescan();

    [Fact]
    public void Start_LogsStartupMessage()
    {
        _service.Start();

        Assert.Contains(_logger.Messages, m => m.Contains("Starting shortcut sync"));
    }

    [Fact]
    public void Stop_LogsStopMessage()
    {
        _service.Start();
        _service.Stop();

        Assert.Contains(_logger.Messages, m => m.Contains("stopped"));
    }

    [Fact]
    public void Dispose_StopsService()
    {
        _service.Start();
        _service.Dispose();

        // Should log stop message
        Assert.Contains(_logger.Messages, m => m.Contains("stopped"));
    }

    [Fact]
    public void Dispose_CanBeCalledMultipleTimes()
    {
        _service.Dispose();
        _service.Dispose(); // Should not throw
    }

    [Fact]
    public void ShortcutInfo_RequiredPropertiesSet()
    {
        var info = new ShortcutInfo
        {
            ShortcutPath = @"C:\Test\shortcut.lnk",
            TargetPath = @"C:\Program Files\App\app.exe",
            DisplayName = "Test App",
            IconPath = @"C:\Program Files\App\app.exe"
        };

        Assert.Equal(@"C:\Test\shortcut.lnk", info.ShortcutPath);
        Assert.Equal(@"C:\Program Files\App\app.exe", info.TargetPath);
        Assert.Equal("Test App", info.DisplayName);
        Assert.Null(info.Arguments);
        Assert.Null(info.WorkingDirectory);
        Assert.Equal(0, info.IconIndex);
    }

    [Fact]
    public void ShortcutInfo_OptionalPropertiesSet()
    {
        var info = new ShortcutInfo
        {
            ShortcutPath = @"C:\Test\shortcut.lnk",
            TargetPath = @"C:\App\app.exe",
            DisplayName = "App",
            IconPath = @"C:\App\app.ico",
            IconIndex = 2,
            Arguments = "--config test.cfg",
            WorkingDirectory = @"C:\App"
        };

        Assert.Equal("--config test.cfg", info.Arguments);
        Assert.Equal(@"C:\App", info.WorkingDirectory);
        Assert.Equal(2, info.IconIndex);
    }

    [Fact]
    public void ParseShortcut_RealSystemShortcut_ReturnsInfo()
    {
        // Try to find a real shortcut on the system
        var startMenu = Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms);
        if (string.IsNullOrEmpty(startMenu) || !Directory.Exists(startMenu))
        {
            return; // Skip on non-Windows
        }

        var shortcuts = Directory.GetFiles(startMenu, "*.lnk", SearchOption.AllDirectories);
        if (shortcuts.Length == 0)
        {
            return; // No shortcuts to test
        }

        var info = _service.ParseShortcut(shortcuts[0]);

        // May be null if the shortcut is invalid or points to non-existent target
        // but should not throw
        if (info != null)
        {
            Assert.NotEmpty(info.ShortcutPath);
            Assert.NotEmpty(info.DisplayName);
        }
    }

    [Fact]
    public void Start_ScansExistingShortcuts()
    {
        _service.Start();

        // Should log scanning message
        Assert.Contains(_logger.Messages, m => m.Contains("Scanned") || m.Contains("Monitoring"));
    }

    [Fact]
    public void DetectedShortcuts_ContainRequiredFields()
    {
        // Create a mock shortcut detection
        var message = new ShortcutDetectedMessage
        {
            ShortcutPath = @"C:\Test\app.lnk",
            TargetPath = @"C:\App\app.exe",
            DisplayName = "Test App",
            IconPath = @"C:\App\app.exe"
        };

        Assert.NotNull(message.ShortcutPath);
        Assert.NotNull(message.TargetPath);
        Assert.NotNull(message.DisplayName);
        Assert.True(message.Timestamp > 0);
    }

    private sealed class TestLogger : IAgentLogger
    {
        public List<string> Messages { get; } = [];

        public void Debug(string message) => Messages.Add($"[DEBUG] {message}");
        public void Info(string message) => Messages.Add($"[INFO] {message}");
        public void Warn(string message) => Messages.Add($"[WARN] {message}");
        public void Error(string message) => Messages.Add($"[ERROR] {message}");
    }
}

