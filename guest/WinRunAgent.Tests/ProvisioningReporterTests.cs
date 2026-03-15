using System.Threading.Channels;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class ProvisioningReporterTests : IDisposable
{
    private readonly Channel<GuestMessage> _outboundChannel = Channel.CreateUnbounded<GuestMessage>();
    private readonly ProvisioningReporter _reporter;

    public ProvisioningReporterTests()
    {
        _reporter = new ProvisioningReporter(_outboundChannel, new TestLogger());
    }

    public void Dispose()
    {
        _reporter.Dispose();
    }

    [Fact]
    public async Task ReportProgressAsync_UpdatesStateAndPublishesProgressMessage()
    {
        await _reporter.ReportProgressAsync(
            ProvisioningPhase.Agent,
            (byte)150,
            "Installing WinRun Agent");

        Assert.Equal(ProvisioningPhase.Agent, _reporter.CurrentPhase);
        Assert.Equal(100, _reporter.CurrentPercent);

        var message = await ReadSingleAsync<ProvisionProgressMessage>(_outboundChannel);
        Assert.Equal(ProvisioningPhase.Agent, message.Phase);
        Assert.Equal(100, message.Percent);
        Assert.Equal("Installing WinRun Agent", message.Message);
    }

    [Fact]
    public async Task ReportErrorAsync_PublishesProvisionErrorMessage()
    {
        await _reporter.ReportProgressAsync(
            ProvisioningPhase.Drivers,
            42,
            "Installing VirtIO drivers");

        await _reporter.ReportErrorAsync(
            ProvisioningPhase.Drivers,
            0x80070005,
            "Access denied",
            isRecoverable: true);

        _ = await ReadSingleAsync<ProvisionProgressMessage>(_outboundChannel);
        var error = await ReadSingleAsync<ProvisionErrorMessage>(_outboundChannel);

        Assert.Equal(ProvisioningPhase.Drivers, error.Phase);
        Assert.Equal(0x80070005u, error.ErrorCode);
        Assert.Equal("Access denied", error.Message);
        Assert.True(error.IsRecoverable);
    }

    [Fact]
    public async Task ReportCompleteAsync_PublishesSuccessfulCompletion()
    {
        await _reporter.ReportCompleteAsync();

        Assert.Equal(ProvisioningPhase.Complete, _reporter.CurrentPhase);
        Assert.Equal(100, _reporter.CurrentPercent);

        var completion = await ReadSingleAsync<ProvisionCompleteMessage>(_outboundChannel);
        Assert.True(completion.Success);
        Assert.NotEmpty(completion.WindowsVersion);
        Assert.NotEmpty(completion.AgentVersion);
    }

    [Fact]
    public async Task ReportFailedAsync_PublishesFailedCompletion()
    {
        await _reporter.ReportFailedAsync("Provisioning aborted");

        var completion = await ReadSingleAsync<ProvisionCompleteMessage>(_outboundChannel);
        Assert.False(completion.Success);
        Assert.Equal("Provisioning aborted", completion.ErrorMessage);
    }

    [Fact]
    public void GetAgentVersion_ReturnsNonEmptyVersionString()
    {
        var version = ProvisioningReporter.GetAgentVersion();
        Assert.NotEmpty(version);
    }

    [Fact]
    public void GetDiskUsageMB_ReturnsValidNonNegativeValue()
    {
        var diskUsage = ProvisioningReporter.GetDiskUsageMB();
        Assert.True(diskUsage >= 0);
    }

    private static async Task<TMessage> ReadSingleAsync<TMessage>(Channel<GuestMessage> channel)
        where TMessage : GuestMessage
    {
        var message = await channel.Reader.ReadAsync();
        return Assert.IsType<TMessage>(message);
    }
}
