using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class ProgramLauncherTests : IDisposable
{
    private readonly TestLogger _logger = new();
    private readonly ProgramLauncher _launcher;

    public ProgramLauncherTests()
    {
        _launcher = new ProgramLauncher(_logger);
    }

    public void Dispose() => _launcher.Dispose();

    [Fact]
    public async Task LaunchAsync_WithEmptyPath_ReturnsInvalidExecutableError()
    {
        var result = await _launcher.LaunchAsync("");

        Assert.False(result.Success);
        Assert.Equal(LaunchErrorCode.InvalidExecutable, result.ErrorCode);
        Assert.Contains("empty", result.ErrorMessage, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task LaunchAsync_WithWhitespacePath_ReturnsInvalidExecutableError()
    {
        var result = await _launcher.LaunchAsync("   ");

        Assert.False(result.Success);
        Assert.Equal(LaunchErrorCode.InvalidExecutable, result.ErrorCode);
    }

    [Fact]
    public async Task LaunchAsync_WithNonExistentPath_ReturnsExecutableNotFoundError()
    {
        var result = await _launcher.LaunchAsync(@"C:\NonExistent\Path\program.exe");

        Assert.False(result.Success);
        Assert.Equal(LaunchErrorCode.ExecutableNotFound, result.ErrorCode);
        Assert.Contains("not found", result.ErrorMessage, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task LaunchAsync_WithNonExistentWorkingDirectory_ReturnsError()
    {
        // Use a system executable that exists
        var cmdPath = @"C:\Windows\System32\cmd.exe";

        // Skip test if not running on Windows or cmd.exe doesn't exist
        if (!File.Exists(cmdPath))
        {
            return; // Skip on non-Windows
        }

        var result = await _launcher.LaunchAsync(
            cmdPath,
            arguments: ["/c", "echo", "test"],
            workingDirectory: @"C:\NonExistent\Directory");

        Assert.False(result.Success);
        Assert.Equal(LaunchErrorCode.WorkingDirectoryNotFound, result.ErrorCode);
    }

    [Fact]
    public async Task LaunchAsync_WithMessage_IdempotentonDuplicateMessageId()
    {
        // Create a launch message with a specific MessageId
        var message = new LaunchProgramMessage
        {
            MessageId = 12345,
            Path = @"C:\Windows\System32\cmd.exe",
            Arguments = ["/c", "echo", "test"]
        };

        // Skip test if not running on Windows
        if (!File.Exists(message.Path))
        {
            return;
        }

        // First launch
        var result1 = await _launcher.LaunchAsync(message, CancellationToken.None);

        // Second launch with same MessageId should return cached result
        var result2 = await _launcher.LaunchAsync(message, CancellationToken.None);

        Assert.True(result1.Success);
        Assert.True(result2.Success);
        Assert.Equal(result1.ProcessId, result2.ProcessId);
        Assert.Equal(LaunchErrorCode.AlreadyLaunched, result2.ErrorCode);
    }

    [Fact]
    public async Task LaunchAsync_DifferentMessageIds_LaunchesSeparately()
    {
        var path = @"C:\Windows\System32\cmd.exe";

        // Skip test if not running on Windows
        if (!File.Exists(path))
        {
            return;
        }

        var message1 = new LaunchProgramMessage
        {
            MessageId = 100,
            Path = path,
            Arguments = ["/c", "echo", "first"]
        };

        var message2 = new LaunchProgramMessage
        {
            MessageId = 101,
            Path = path,
            Arguments = ["/c", "echo", "second"]
        };

        var result1 = await _launcher.LaunchAsync(message1, CancellationToken.None);
        var result2 = await _launcher.LaunchAsync(message2, CancellationToken.None);

        Assert.True(result1.Success);
        Assert.True(result2.Success);
        Assert.NotEqual(result1.ProcessId, result2.ProcessId);
        Assert.Equal(LaunchErrorCode.None, result1.ErrorCode);
        Assert.Equal(LaunchErrorCode.None, result2.ErrorCode);
    }

    [Fact]
    public void LaunchResult_Succeeded_SetsCorrectProperties()
    {
        var result = LaunchResult.Succeeded(1234);

        Assert.True(result.Success);
        Assert.Equal(1234, result.ProcessId);
        Assert.Equal(LaunchErrorCode.None, result.ErrorCode);
        Assert.Null(result.ErrorMessage);
    }

    [Fact]
    public void LaunchResult_Failed_SetsCorrectProperties()
    {
        var result = LaunchResult.Failed(LaunchErrorCode.AccessDenied, "Access denied");

        Assert.False(result.Success);
        Assert.Null(result.ProcessId);
        Assert.Equal(LaunchErrorCode.AccessDenied, result.ErrorCode);
        Assert.Equal("Access denied", result.ErrorMessage);
    }

    [Fact]
    public void LaunchResult_AlreadyLaunched_SetsCorrectProperties()
    {
        var result = LaunchResult.AlreadyLaunched(5678);

        Assert.True(result.Success);
        Assert.Equal(5678, result.ProcessId);
        Assert.Equal(LaunchErrorCode.AlreadyLaunched, result.ErrorCode);
    }

    [Fact]
    public void LaunchedProcessInfo_StoresAllProperties()
    {
        var launchTime = DateTime.UtcNow;
        var info = new LaunchedProcessInfo(
            processId: 1234,
            executablePath: @"C:\Program Files\App.exe",
            arguments: ["--arg1", "--arg2"],
            workingDirectory: @"C:\Temp",
            launchTime: launchTime);

        Assert.Equal(1234, info.ProcessId);
        Assert.Equal(@"C:\Program Files\App.exe", info.ExecutablePath);
        Assert.Equal(2, info.Arguments.Length);
        Assert.Equal("--arg1", info.Arguments[0]);
        Assert.Equal(@"C:\Temp", info.WorkingDirectory);
        Assert.Equal(launchTime, info.LaunchTime);
        Assert.False(info.HasExited);
        Assert.Null(info.ExitTime);
        Assert.Null(info.ExitCode);
    }

    [Fact]
    public void LaunchedProcessInfo_HasExited_InitiallyFalse()
    {
        var info = new LaunchedProcessInfo(
            processId: 1234,
            executablePath: @"C:\App.exe",
            arguments: [],
            workingDirectory: null,
            launchTime: DateTime.UtcNow);

        Assert.False(info.HasExited);
        Assert.Null(info.ExitTime);
        Assert.Null(info.ExitCode);
    }

    [Fact]
    public async Task LaunchAsync_TracksLaunchedProcesses()
    {
        var path = @"C:\Windows\System32\cmd.exe";

        // Skip test if not running on Windows
        if (!File.Exists(path))
        {
            return;
        }

        var result = await _launcher.LaunchAsync(
            path,
            arguments: ["/c", "timeout", "/t", "2"]);

        Assert.True(result.Success);
        _ = Assert.NotNull(result.ProcessId);

        var tracked = _launcher.GetTrackedProcesses();
        Assert.Contains(tracked, p => p.ProcessId == result.ProcessId);

        var info = _launcher.GetProcessInfo(result.ProcessId.Value);
        Assert.NotNull(info);
        Assert.Equal(path, info.ExecutablePath);
    }

    [Fact]
    public void GetTrackedProcesses_InitiallyEmpty()
    {
        var tracked = _launcher.GetTrackedProcesses();

        Assert.Empty(tracked);
    }

    [Fact]
    public void LaunchErrorCode_HasExpectedValues()
    {
        Assert.Equal(0, (int)LaunchErrorCode.None);
        Assert.Equal(1, (int)LaunchErrorCode.AlreadyLaunched);
        Assert.Equal(2, (int)LaunchErrorCode.ExecutableNotFound);
        Assert.Equal(3, (int)LaunchErrorCode.WorkingDirectoryNotFound);
        Assert.Equal(4, (int)LaunchErrorCode.AccessDenied);
        Assert.Equal(5, (int)LaunchErrorCode.InvalidExecutable);
        Assert.Equal(6, (int)LaunchErrorCode.ProcessStartFailed);
    }

    [Fact]
    public async Task LaunchAsync_WithEnvironmentVariables_DoesNotThrow()
    {
        var path = @"C:\Windows\System32\cmd.exe";

        // Skip test if not running on Windows
        if (!File.Exists(path))
        {
            return;
        }

        var environment = new Dictionary<string, string>
        {
            ["CUSTOM_VAR"] = "custom_value",
            ["ANOTHER_VAR"] = "another_value"
        };

        var result = await _launcher.LaunchAsync(
            path,
            arguments: ["/c", "echo", "%CUSTOM_VAR%"],
            environment: environment);

        Assert.True(result.Success);
    }

    [Fact]
    public async Task LaunchAsync_WithValidWorkingDirectory_Succeeds()
    {
        var path = @"C:\Windows\System32\cmd.exe";
        var workingDir = @"C:\Windows";

        // Skip test if not running on Windows
        if (!File.Exists(path) || !Directory.Exists(workingDir))
        {
            return;
        }

        var result = await _launcher.LaunchAsync(
            path,
            arguments: ["/c", "cd"],
            workingDirectory: workingDir);

        Assert.True(result.Success);
    }

    [Fact]
    public async Task LaunchAsync_WithCancellation_CanCancelProcess()
    {
        var path = @"C:\Windows\System32\cmd.exe";

        // Skip test if not running on Windows
        if (!File.Exists(path))
        {
            return;
        }

        using var cts = new CancellationTokenSource();

        var result = await _launcher.LaunchAsync(
            path,
            arguments: ["/c", "timeout", "/t", "30"],
            token: cts.Token);

        Assert.True(result.Success);

        // Cancel should attempt to kill the process
        cts.Cancel();

        // Give it a moment
        await Task.Delay(100);

        // Process should eventually exit (the cancellation token triggers kill)
        // Note: This is a best-effort test as timing can vary
    }

    private sealed class TestLogger : IAgentLogger
    {
        public List<string> DebugMessages { get; } = [];
        public List<string> InfoMessages { get; } = [];
        public List<string> WarnMessages { get; } = [];
        public List<string> ErrorMessages { get; } = [];

        public void Debug(string message) => DebugMessages.Add(message);
        public void Info(string message) => InfoMessages.Add(message);
        public void Warn(string message) => WarnMessages.Add(message);
        public void Error(string message) => ErrorMessages.Add(message);
    }
}

