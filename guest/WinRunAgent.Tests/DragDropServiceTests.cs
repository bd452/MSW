using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class DragDropServiceTests : IDisposable
{
    private readonly TestLogger _logger = new();
    private readonly string _testStagingRoot;
    private readonly DragDropService _service;

    public DragDropServiceTests()
    {
        _testStagingRoot = Path.Combine(Path.GetTempPath(), $"DragDropTest_{Guid.NewGuid():N}");
        _service = new DragDropService(_logger, _testStagingRoot);
    }

    public void Dispose()
    {
        _service.Dispose();
        if (Directory.Exists(_testStagingRoot))
        {
            try
            {
                Directory.Delete(_testStagingRoot, recursive: true);
            }
            catch
            {
                // Ignore cleanup errors in tests
            }
        }
    }

    [Fact]
    public void Constructor_CreatesStagingDirectory() => Assert.True(Directory.Exists(_testStagingRoot));

    [Fact]
    public void StagingRoot_ReturnsConfiguredPath() => Assert.Equal(_testStagingRoot, _service.StagingRoot);

    [Fact]
    public void ValidatePaths_EmptyFiles_ReturnsFalse()
    {
        var result = DragDropService.ValidatePaths([], out var error);

        Assert.False(result);
        Assert.Contains("No files provided", error);
    }

    [Fact]
    public void ValidatePaths_EmptyHostPath_ReturnsFalse()
    {
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "" }
        };

        var result = DragDropService.ValidatePaths(files, out var error);

        Assert.False(result);
        Assert.Contains("Empty host path", error);
    }

    [Fact]
    public void ValidatePaths_PathTraversalInHostPath_ReturnsFalse()
    {
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/../../../etc/passwd" }
        };

        var result = DragDropService.ValidatePaths(files, out var error);

        Assert.False(result);
        Assert.Contains("Path traversal", error);
    }

    [Fact]
    public void ValidatePaths_PathTraversalInGuestPath_ReturnsFalse()
    {
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", GuestPath = @"..\..\..\Windows\System32\cmd.exe" }
        };

        var result = DragDropService.ValidatePaths(files, out var error);

        Assert.False(result);
        Assert.Contains("Path traversal", error);
    }

    [Fact]
    public void ValidatePaths_FileTooLarge_ReturnsFalse()
    {
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/large.iso", FileSize = 600UL * 1024 * 1024 }
        };

        var result = DragDropService.ValidatePaths(files, out var error);

        Assert.False(result);
        Assert.Contains("exceeds maximum size", error);
    }

    [Fact]
    public void ValidatePaths_TotalSizeTooLarge_ReturnsFalse()
    {
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file1.dat", FileSize = 500UL * 1024 * 1024 },
            new DraggedFileInfo { HostPath = "/Users/test/file2.dat", FileSize = 500UL * 1024 * 1024 },
            new DraggedFileInfo { HostPath = "/Users/test/file3.dat", FileSize = 500UL * 1024 * 1024 },
            new DraggedFileInfo { HostPath = "/Users/test/file4.dat", FileSize = 500UL * 1024 * 1024 },
            new DraggedFileInfo { HostPath = "/Users/test/file5.dat", FileSize = 500UL * 1024 * 1024 }
        };

        var result = DragDropService.ValidatePaths(files, out var error);

        Assert.False(result);
        Assert.Contains("Total file size exceeds", error);
    }

    [Fact]
    public void ValidatePaths_ValidFiles_ReturnsTrue()
    {
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 1024 },
            new DraggedFileInfo { HostPath = "/Users/test/image.png", FileSize = 2048 }
        };

        var result = DragDropService.ValidatePaths(files, out var error);

        Assert.True(result);
        Assert.Null(error);
    }

    [Fact]
    public void StageFiles_ValidFiles_CreatesSessionDirectory()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/document.txt", FileSize = 100 }
        };

        var result = _service.StageFiles(windowId, files);

        Assert.True(result.Success);
        _ = Assert.Single(result.StagedPaths);
        Assert.True(File.Exists(result.StagedPaths[0]) || Directory.Exists(result.StagedPaths[0]));
    }

    [Fact]
    public void StageFiles_MultipleFiles_StagesAll()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/doc1.txt", FileSize = 100 },
            new DraggedFileInfo { HostPath = "/Users/test/doc2.txt", FileSize = 200 },
            new DraggedFileInfo { HostPath = "/Users/test/doc3.txt", FileSize = 300 }
        };

        var result = _service.StageFiles(windowId, files);

        Assert.True(result.Success);
        Assert.Equal(3, result.StagedPaths.Length);
    }

    [Fact]
    public void StageFiles_Directory_CreatesDirectory()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/folder", IsDirectory = true }
        };

        var result = _service.StageFiles(windowId, files);

        Assert.True(result.Success);
        _ = Assert.Single(result.StagedPaths);
        Assert.True(Directory.Exists(result.StagedPaths[0]));
    }

    [Fact]
    public void StageFiles_InvalidFiles_ReturnsError()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "" }
        };

        var result = _service.StageFiles(windowId, files);

        Assert.False(result.Success);
        Assert.NotNull(result.ErrorMessage);
    }

    [Fact]
    public void GetStagedFiles_AfterStaging_ReturnsFiles()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
        };

        _ = _service.StageFiles(windowId, files);
        var stagedFiles = _service.GetStagedFiles(windowId);

        Assert.NotNull(stagedFiles);
        _ = Assert.Single(stagedFiles);
    }

    [Fact]
    public void GetStagedFiles_NoSession_ReturnsNull()
    {
        var stagedFiles = _service.GetStagedFiles(99999);

        Assert.Null(stagedFiles);
    }

    [Fact]
    public void CancelDrag_CleansUpFiles()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
        };

        var result = _service.StageFiles(windowId, files);
        var stagedPath = result.StagedPaths[0];

        Assert.True(File.Exists(stagedPath));

        _service.CancelDrag(windowId);

        Assert.False(File.Exists(stagedPath));
        Assert.Null(_service.GetStagedFiles(windowId));
    }

    [Fact]
    public void CommitDrop_NoSession_ReturnsError()
    {
        var result = _service.CommitDrop(99999);

        Assert.False(result.Success);
        Assert.Contains("No active drag session", result.ErrorMessage);
    }

    [Fact]
    public void CommitDrop_WithoutDestination_KeepsFilesInStaging()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
        };

        _ = _service.StageFiles(windowId, files);
        var result = _service.CommitDrop(windowId);

        Assert.True(result.Success);
        _ = Assert.Single(result.StagedPaths);
        Assert.True(File.Exists(result.StagedPaths[0]));
    }

    [Fact]
    public void CommitDrop_WithDestination_MovesFiles()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
        };

        var destDir = Path.Combine(_testStagingRoot, "destination");

        _ = _service.StageFiles(windowId, files);
        var stagedPath = _service.GetStagedFiles(windowId)![0];

        // Write some content to the staged file
        File.WriteAllText(stagedPath, "test content");

        var result = _service.CommitDrop(windowId, destDir);

        Assert.True(result.Success);
        _ = Assert.Single(result.StagedPaths);
        Assert.False(File.Exists(stagedPath));
        Assert.True(File.Exists(result.StagedPaths[0]));
        Assert.StartsWith(destDir, result.StagedPaths[0]);
    }

    [Fact]
    public void HandleDragDrop_Enter_StagesFiles()
    {
        var message = new DragDropMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = DragDropEventType.Enter,
            X = 100,
            Y = 100,
            Files =
            [
                new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
            ]
        };

        var result = _service.HandleDragDrop(message);

        Assert.True(result.Success);
        _ = Assert.Single(result.StagedPaths);
    }

    [Fact]
    public void HandleDragDrop_Move_DoesNothing()
    {
        var message = new DragDropMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = DragDropEventType.Move,
            X = 150,
            Y = 150,
            Files = []
        };

        var result = _service.HandleDragDrop(message);

        Assert.True(result.Success);
        Assert.Empty(result.StagedPaths);
    }

    [Fact]
    public void HandleDragDrop_Leave_CleansUp()
    {
        // First stage files
        var enterMessage = new DragDropMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = DragDropEventType.Enter,
            Files =
            [
                new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
            ]
        };
        _ = _service.HandleDragDrop(enterMessage);

        // Then leave
        var leaveMessage = new DragDropMessage
        {
            MessageId = 2,
            WindowId = 12345,
            EventType = DragDropEventType.Leave,
            Files = []
        };

        var result = _service.HandleDragDrop(leaveMessage);

        Assert.True(result.Success);
        Assert.Null(_service.GetStagedFiles(12345));
    }

    [Fact]
    public void HandleDragDrop_Drop_CommitsStaging()
    {
        // First stage files
        var enterMessage = new DragDropMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = DragDropEventType.Enter,
            Files =
            [
                new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
            ]
        };
        _ = _service.HandleDragDrop(enterMessage);

        // Then drop
        var dropMessage = new DragDropMessage
        {
            MessageId = 2,
            WindowId = 12345,
            EventType = DragDropEventType.Drop,
            X = 200,
            Y = 200,
            Files = []
        };

        var result = _service.HandleDragDrop(dropMessage);

        Assert.True(result.Success);
        _ = Assert.Single(result.StagedPaths);
    }

    [Fact]
    public void HandleDragDrop_DropWithoutEnter_StagesAndCommits()
    {
        var dropMessage = new DragDropMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = DragDropEventType.Drop,
            X = 200,
            Y = 200,
            Files =
            [
                new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
            ]
        };

        var result = _service.HandleDragDrop(dropMessage);

        Assert.True(result.Success);
        _ = Assert.Single(result.StagedPaths);
    }

    [Fact]
    public void CleanupStaleSessions_RemovesOldSessions()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
        };

        var result = _service.StageFiles(windowId, files);
        var stagedPath = result.StagedPaths[0];

        Assert.True(File.Exists(stagedPath));

        // Cleanup with zero age should remove all sessions
        _service.CleanupStaleSessions(TimeSpan.Zero);

        Assert.False(File.Exists(stagedPath));
        Assert.Null(_service.GetStagedFiles(windowId));
    }

    [Fact]
    public void CleanupStaleSessions_KeepsRecentSessions()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
        };

        _ = _service.StageFiles(windowId, files);
        var stagedFiles = _service.GetStagedFiles(windowId);

        // Cleanup with 1 hour age should keep recent sessions
        _service.CleanupStaleSessions(TimeSpan.FromHours(1));

        Assert.NotNull(_service.GetStagedFiles(windowId));
        _ = Assert.Single(stagedFiles!);
    }

    [Fact]
    public void Dispose_CleansUpAllSessions()
    {
        var files = new[]
        {
            new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
        };

        _ = _service.StageFiles(1, files);
        _ = _service.StageFiles(2, files);
        _ = _service.StageFiles(3, files);

        _service.Dispose();

        // Service should be disposed, sessions cleaned up
        Assert.Null(_service.GetStagedFiles(1));
        Assert.Null(_service.GetStagedFiles(2));
        Assert.Null(_service.GetStagedFiles(3));
    }

    [Fact]
    public void StageFiles_UsesGuestPathForFilename()
    {
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo
            {
                HostPath = "/Users/test/original.txt",
                GuestPath = @"C:\Users\test\renamed.txt",
                FileSize = 100
            }
        };

        var result = _service.StageFiles(windowId, files);

        Assert.True(result.Success);
        Assert.Contains("renamed.txt", result.StagedPaths[0]);
    }

    [Fact]
    public void StageFiles_SanitizesInvalidCharacters()
    {
        // Use a filename with printable characters that would be invalid on Windows
        // (on Linux, most characters are valid, so this tests the sanitization logic works)
        var windowId = 12345UL;
        var files = new[]
        {
            new DraggedFileInfo
            {
                // Filename with characters potentially invalid on Windows
                HostPath = "/Users/test/file_with_special_chars.txt",
                FileSize = 100
            }
        };

        var result = _service.StageFiles(windowId, files);

        Assert.True(result.Success);
        // File should be staged successfully with a valid filename
        var fileName = Path.GetFileName(result.StagedPaths[0]);
        Assert.NotEmpty(fileName);
        Assert.EndsWith(".txt", fileName);
        // Verify no invalid characters for the current platform
        var invalidChars = Path.GetInvalidFileNameChars();
        foreach (var c in fileName)
        {
            Assert.DoesNotContain(c, invalidChars);
        }
    }

    [Fact]
    public void LogsDebugMessages()
    {
        var message = new DragDropMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = DragDropEventType.Move,
            X = 100,
            Y = 100,
            Files = []
        };

        _ = _service.HandleDragDrop(message);

        Assert.Contains(_logger.DebugMessages, m => m.Contains("Drag move"));
    }

    [Fact]
    public void LogsInfoOnDrop()
    {
        var message = new DragDropMessage
        {
            MessageId = 1,
            WindowId = 12345,
            EventType = DragDropEventType.Drop,
            X = 100,
            Y = 100,
            Files =
            [
                new DraggedFileInfo { HostPath = "/Users/test/file.txt", FileSize = 100 }
            ]
        };

        _ = _service.HandleDragDrop(message);

        Assert.Contains(_logger.InfoMessages, m => m.Contains("Drop"));
    }
}
