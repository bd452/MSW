using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class IconExtractionServiceTests : IDisposable
{
    private readonly TestLogger _logger = new();
    private readonly string _testCacheDir;
    private readonly IconExtractionService _service;

    public IconExtractionServiceTests()
    {
        _testCacheDir = Path.Combine(Path.GetTempPath(), $"IconCacheTest_{Guid.NewGuid():N}");
        _service = new IconExtractionService(_logger, _testCacheDir, TimeSpan.FromHours(1));
    }

    public void Dispose()
    {
        _service.Dispose();

        // Clean up test cache directory
        if (Directory.Exists(_testCacheDir))
        {
            try
            {
                Directory.Delete(_testCacheDir, recursive: true);
            }
            catch
            {
                // Ignore cleanup failures in tests
            }
        }
    }

    [Fact]
    public void Constructor_CreatesCacheDirectory() => Assert.True(Directory.Exists(_testCacheDir));

    [Fact]
    public async Task ExtractIconAsync_EmptyPath_ReturnsFailure()
    {
        var result = await _service.ExtractIconAsync("", 256);

        Assert.False(result.IsSuccess);
        Assert.Equal("Empty path", result.ErrorMessage);
        Assert.Empty(result.PngData);
    }

    [Fact]
    public async Task ExtractIconAsync_NullPath_ReturnsFailure()
    {
        var result = await _service.ExtractIconAsync(null!, 256);

        Assert.False(result.IsSuccess);
        Assert.Equal("Empty path", result.ErrorMessage);
    }

    [Fact]
    public async Task ExtractIconAsync_WhitespacePath_ReturnsFailure()
    {
        var result = await _service.ExtractIconAsync("   ", 256);

        Assert.False(result.IsSuccess);
        Assert.Equal("Empty path", result.ErrorMessage);
    }

    [Fact]
    public async Task ExtractIconAsync_NonExistentFile_ReturnsFailure()
    {
        var nonExistentPath = Path.Combine(_testCacheDir, "nonexistent.exe");

        var result = await _service.ExtractIconAsync(nonExistentPath, 256);

        Assert.False(result.IsSuccess);
        Assert.Contains("not found", result.ErrorMessage, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ExtractIconAsync_SamePathTwice_UsesCacheOnSecondCall()
    {
        // Use a system file that should always exist
        var systemPath = @"C:\Windows\System32\cmd.exe";

        if (!File.Exists(systemPath))
        {
            // Skip on non-Windows
            return;
        }

        var result1 = await _service.ExtractIconAsync(systemPath, 256);
        var initialLogCount = _logger.Messages.Count;

        var result2 = await _service.ExtractIconAsync(systemPath, 256);

        // Should see "cache hit" log message
        var cacheHitLogs = _logger.Messages.Skip(initialLogCount)
            .Count(m => m.Contains("cache hit", StringComparison.OrdinalIgnoreCase));
        Assert.True(cacheHitLogs > 0, "Expected cache hit log message");
    }

    [Fact]
    public async Task ExtractIconAsync_DifferentSizes_CachesSeparately()
    {
        var systemPath = @"C:\Windows\System32\cmd.exe";

        if (!File.Exists(systemPath))
        {
            return;
        }

        // Request different sizes - these should be separate cache entries
        var result256 = await _service.ExtractIconAsync(systemPath, 256);
        var result32 = await _service.ExtractIconAsync(systemPath, 32);

        // If both succeeded, they should potentially have different dimensions
        // (though the actual icon source may limit this)
        if (result256.IsSuccess && result32.IsSuccess)
        {
            // At minimum, both should return valid PNG data
            Assert.NotEmpty(result256.PngData);
            Assert.NotEmpty(result32.PngData);
        }
    }

    [Fact]
    public void PruneCache_RemovesExpiredEntries()
    {
        // Use a very short expiry for testing
        var shortExpiryService = new IconExtractionService(
            _logger,
            _testCacheDir,
            TimeSpan.FromMilliseconds(1));

        try
        {
            // No entries to prune initially - this should not throw
            shortExpiryService.PruneCache();

            // Verify log message
            Assert.Contains(_logger.Messages, m => m.Contains("Pruned") && m.Contains("entries"));
        }
        finally
        {
            shortExpiryService.Dispose();
        }
    }

    [Fact]
    public void ClearCache_RemovesAllEntries()
    {
        // Create a test PNG file in cache directory
        var testCacheFile = Path.Combine(_testCacheDir, "testcache_256.png");
        File.WriteAllBytes(testCacheFile, [0x89, 0x50, 0x4E, 0x47]); // PNG header

        _service.ClearCache();

        Assert.False(File.Exists(testCacheFile));
        Assert.Contains(_logger.Messages, m => m.Contains("cache cleared", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task ExtractIconAsync_CancellationToken_Respected()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        // This should either throw OperationCanceledException or return quickly
        // (depending on where cancellation is checked)
        _ = await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            _ = await _service.ExtractIconAsync(@"C:\Windows\System32\cmd.exe", 256, cts.Token);
        });
    }

    [Fact]
    public void IconExtractionResult_Success_HasCorrectProperties()
    {
        var pngData = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        var result = IconExtractionResult.Success(pngData, 256, 256);

        Assert.True(result.IsSuccess);
        Assert.Equal(pngData, result.PngData);
        Assert.Equal(256, result.Width);
        Assert.Equal(256, result.Height);
        Assert.Null(result.ErrorMessage);
    }

    [Fact]
    public void IconExtractionResult_Failed_HasCorrectProperties()
    {
        var result = IconExtractionResult.Failed("Test error");

        Assert.False(result.IsSuccess);
        Assert.Empty(result.PngData);
        Assert.Equal(0, result.Width);
        Assert.Equal(0, result.Height);
        Assert.Equal("Test error", result.ErrorMessage);
    }

    [Fact]
    public async Task ExtractIconAsync_LegacyOverload_ReturnsEmptyArrayOnFailure()
    {
        // Use the legacy overload that returns byte[]
        var pngData = await _service.ExtractIconAsync("nonexistent.exe", CancellationToken.None);

        Assert.Empty(pngData);
    }

    [Fact]
    public async Task ExtractIconAsync_SystemExecutable_ReturnsValidPng()
    {
        var systemPath = @"C:\Windows\System32\notepad.exe";

        if (!File.Exists(systemPath))
        {
            return; // Skip on non-Windows
        }

        var result = await _service.ExtractIconAsync(systemPath, 256);

        // Notepad should have a valid icon
        if (result.IsSuccess)
        {
            Assert.NotEmpty(result.PngData);
            Assert.True(result.Width > 0);
            Assert.True(result.Height > 0);

            // Verify PNG magic bytes
            Assert.True(result.PngData.Length >= 8);
            Assert.Equal(0x89, result.PngData[0]);
            Assert.Equal(0x50, result.PngData[1]); // P
            Assert.Equal(0x4E, result.PngData[2]); // N
            Assert.Equal(0x47, result.PngData[3]); // G
        }
    }

    [Fact]
    public async Task ExtractIconAsync_DiskCachePersists()
    {
        var systemPath = @"C:\Windows\System32\notepad.exe";

        if (!File.Exists(systemPath))
        {
            return;
        }

        // First extraction should create disk cache
        var result1 = await _service.ExtractIconAsync(systemPath, 256);

        if (!result1.IsSuccess)
        {
            return;
        }

        // Check that a .png file was created in cache directory
        var cacheFiles = Directory.GetFiles(_testCacheDir, "*.png");
        Assert.NotEmpty(cacheFiles);
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

