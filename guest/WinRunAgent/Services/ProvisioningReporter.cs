using System.Reflection;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.Win32;

namespace WinRun.Agent.Services;

/// <summary>
/// Reports provisioning status to the host during Windows setup.
/// Used by provisioning scripts to communicate progress, errors, and completion.
/// </summary>
public sealed class ProvisioningReporter : IDisposable
{
    private readonly Channel<GuestMessage> _outboundChannel;
    private readonly IAgentLogger _logger;
    private bool _disposed;

    /// <summary>
    /// Path to the provisioning status file for inter-process communication.
    /// Provisioning scripts can write status here when the agent isn't available.
    /// </summary>
    public static readonly string StatusFilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "WinRun",
        "provisioning-status.json");

    /// <summary>
    /// Creates a new provisioning reporter.
    /// </summary>
    public ProvisioningReporter(
        Channel<GuestMessage> outboundChannel,
        IAgentLogger logger)
    {
        _outboundChannel = outboundChannel;
        _logger = logger;
    }

    /// <summary>
    /// Gets or sets the current provisioning phase.
    /// </summary>
    public ProvisioningPhase CurrentPhase { get; private set; } = ProvisioningPhase.Drivers;

    /// <summary>
    /// Gets or sets the current progress percentage (0-100).
    /// </summary>
    public byte CurrentPercent { get; private set; }

    /// <summary>
    /// Reports progress within the current phase.
    /// </summary>
    public async Task ReportProgressAsync(
        ProvisioningPhase phase,
        byte percent,
        string message,
        CancellationToken cancellationToken = default)
    {
        CurrentPhase = phase;
        CurrentPercent = Math.Min((byte)100, percent);

        _logger.Info($"[Provisioning] {phase}: {percent}% - {message}");

        var msg = SpiceMessageSerializer.CreateProvisionProgress(phase, percent, message);
        await _outboundChannel.Writer.WriteAsync(msg, cancellationToken);

        // Also write to status file for persistence/recovery
        await WriteStatusFileAsync(phase, percent, message);
    }

    /// <summary>
    /// Reports an error during provisioning.
    /// </summary>
    public async Task ReportErrorAsync(
        ProvisioningPhase phase,
        uint errorCode,
        string message,
        bool isRecoverable = false,
        CancellationToken cancellationToken = default)
    {
        _logger.Error($"[Provisioning] {phase} error (0x{errorCode:X8}): {message}");

        var msg = SpiceMessageSerializer.CreateProvisionError(phase, errorCode, message, isRecoverable);
        await _outboundChannel.Writer.WriteAsync(msg, cancellationToken);

        await WriteStatusFileAsync(phase, CurrentPercent, $"Error: {message}", errorCode);
    }

    /// <summary>
    /// Reports successful completion of provisioning.
    /// </summary>
    public async Task ReportCompleteAsync(CancellationToken cancellationToken = default)
    {
        var diskUsageMB = GetDiskUsageMB();
        var windowsVersion = GetWindowsVersion();
        var agentVersion = GetAgentVersion();

        _logger.Info(
            $"[Provisioning] Complete - Windows: {windowsVersion}, " +
            $"Agent: {agentVersion}, Disk: {diskUsageMB}MB");

        CurrentPhase = ProvisioningPhase.Complete;
        CurrentPercent = 100;

        var msg = SpiceMessageSerializer.CreateProvisionComplete(diskUsageMB, windowsVersion, agentVersion);
        await _outboundChannel.Writer.WriteAsync(msg, cancellationToken);

        // Clean up status file on success
        DeleteStatusFile();
    }

    /// <summary>
    /// Reports failed provisioning.
    /// </summary>
    public async Task ReportFailedAsync(
        string errorMessage,
        CancellationToken cancellationToken = default)
    {
        var windowsVersion = GetWindowsVersion();

        _logger.Error($"[Provisioning] Failed: {errorMessage}");

        var msg = SpiceMessageSerializer.CreateProvisionFailed(errorMessage, windowsVersion);
        await _outboundChannel.Writer.WriteAsync(msg, cancellationToken);
    }

    /// <summary>
    /// Gets the Windows version string from the Registry.
    /// </summary>
    public static string GetWindowsVersion()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows NT\CurrentVersion");

            if (key != null)
            {
                var productName = key.GetValue("ProductName")?.ToString();
                var displayVersion = key.GetValue("DisplayVersion")?.ToString();

                if (!string.IsNullOrEmpty(productName))
                {
                    return string.IsNullOrEmpty(displayVersion)
                        ? productName
                        : $"{productName} {displayVersion}";
                }
            }
        }
        catch
        {
            // Fall back to basic version info
        }

        return $"Windows {Environment.OSVersion.Version}";
    }

    /// <summary>
    /// Gets the WinRun Agent version.
    /// </summary>
    public static string GetAgentVersion()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var version = assembly.GetName().Version;
        return version?.ToString(3) ?? "1.0.0";
    }

    /// <summary>
    /// Gets the disk usage of the Windows partition in megabytes.
    /// </summary>
    public static ulong GetDiskUsageMB()
    {
        try
        {
            var systemDrive = Path.GetPathRoot(Environment.SystemDirectory);
            if (string.IsNullOrEmpty(systemDrive))
            {
                return 0;
            }

            var driveInfo = new DriveInfo(systemDrive);
            var usedBytes = (ulong)(driveInfo.TotalSize - driveInfo.TotalFreeSpace);
            return usedBytes / (1024 * 1024);
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>
    /// Reads the last provisioning status from the status file.
    /// Returns null if no status file exists or it's invalid.
    /// </summary>
    public static ProvisioningStatusInfo? ReadStatusFile()
    {
        try
        {
            if (!File.Exists(StatusFilePath))
            {
                return null;
            }

            var json = File.ReadAllText(StatusFilePath);
            return JsonSerializer.Deserialize<ProvisioningStatusInfo>(json);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Writes the current provisioning status to the status file.
    /// </summary>
    private static async Task WriteStatusFileAsync(
        ProvisioningPhase phase,
        byte percent,
        string message,
        uint? errorCode = null)
    {
        try
        {
            var status = new ProvisioningStatusInfo
            {
                Phase = phase.ToString().ToLowerInvariant(),
                Percent = percent,
                Message = message,
                ErrorCode = errorCode,
                Timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
            };

            var directory = Path.GetDirectoryName(StatusFilePath);
            if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
            {
                _ = Directory.CreateDirectory(directory);
            }

            var json = JsonSerializer.Serialize(status, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(StatusFilePath, json);
        }
        catch
        {
            // Best effort - don't fail provisioning if we can't write status file
        }
    }

    /// <summary>
    /// Deletes the provisioning status file.
    /// </summary>
    private static void DeleteStatusFile()
    {
        try
        {
            if (File.Exists(StatusFilePath))
            {
                File.Delete(StatusFilePath);
            }
        }
        catch
        {
            // Best effort
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
    }
}

/// <summary>
/// Provisioning status information stored in the status file.
/// </summary>
public sealed class ProvisioningStatusInfo
{
    /// <summary>
    /// Current phase name (lowercase).
    /// </summary>
    public required string Phase { get; init; }

    /// <summary>
    /// Progress percentage (0-100).
    /// </summary>
    public required byte Percent { get; init; }

    /// <summary>
    /// Human-readable status message.
    /// </summary>
    public required string Message { get; init; }

    /// <summary>
    /// Error code if an error occurred.
    /// </summary>
    public uint? ErrorCode { get; init; }

    /// <summary>
    /// Timestamp when this status was written (Unix milliseconds).
    /// </summary>
    public long Timestamp { get; init; }
}
