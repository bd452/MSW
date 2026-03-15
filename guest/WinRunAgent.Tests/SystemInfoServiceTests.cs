using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class SystemInfoServiceTests
{
    [SkippableFact]
    public void DetectCapabilities_IncludesBaselineCapabilities()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "SystemInfoService requires Windows APIs");

        var service = new SystemInfoService(new TestLogger());
        var capabilities = service.DetectCapabilities();

        Assert.True(capabilities.HasFlag(GuestCapabilities.WindowTracking));
        Assert.True(capabilities.HasFlag(GuestCapabilities.ClipboardSync));
        Assert.True(capabilities.HasFlag(GuestCapabilities.DragDrop));
        Assert.True(capabilities.HasFlag(GuestCapabilities.IconExtraction));
        Assert.True(capabilities.HasFlag(GuestCapabilities.ShortcutDetection));
    }

    [SkippableFact]
    public void CreateCapabilityMessage_UsesCurrentProtocolAndDetectedCapabilities()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "SystemInfoService requires Windows APIs");

        var service = new SystemInfoService(new TestLogger());
        var message = service.CreateCapabilityMessage();

        Assert.Equal(SpiceProtocolVersion.Combined, message.ProtocolVersion);
        Assert.True(message.Capabilities.HasFlag(GuestCapabilities.WindowTracking));
        Assert.NotEmpty(message.AgentVersion);
        Assert.NotEmpty(message.OsVersion);
    }

    [SkippableFact]
    public void GatherDpiInfo_ReturnsAtLeastOneMonitorAndPrimaryDpi()
    {
        Skip.IfNot(OperatingSystem.IsWindows(), "SystemInfoService requires Windows APIs");

        var service = new SystemInfoService(new TestLogger());
        var dpiInfo = service.GatherDpiInfo();

        Assert.True(dpiInfo.PrimaryDpi > 0);
        Assert.True(dpiInfo.ScaleFactor > 0);
        Assert.NotEmpty(dpiInfo.Monitors);
        Assert.Contains(dpiInfo.Monitors, m => m.IsPrimary);
    }
}
