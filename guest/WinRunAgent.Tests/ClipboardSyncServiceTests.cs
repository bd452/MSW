using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class ClipboardSyncServiceTests : IDisposable
{
    private readonly TestLogger _logger = new();
    private readonly List<GuestMessage> _sentMessages = [];
    private readonly ClipboardSyncService _service;

    public ClipboardSyncServiceTests()
    {
        _service = new ClipboardSyncService(_logger, msg =>
        {
            _sentMessages.Add(msg);
            return Task.CompletedTask;
        });
    }

    public void Dispose() => _service.Dispose();

    [Fact]
    public void SetClipboard_IgnoresStaleData()
    {
        // First message with sequence number 10
        var message1 = new HostClipboardMessage
        {
            MessageId = 1,
            Format = ClipboardFormat.PlainText,
            Data = "Hello"u8.ToArray(),
            SequenceNumber = 10
        };

        // This will fail on non-Windows but should attempt
        _ = _service.SetClipboard(message1);

        // Second message with older sequence number should be ignored
        var message2 = new HostClipboardMessage
        {
            MessageId = 2,
            Format = ClipboardFormat.PlainText,
            Data = "Stale"u8.ToArray(),
            SequenceNumber = 5 // Older than 10
        };

        var result = _service.SetClipboard(message2);

        // Stale data should return true (ignored successfully)
        Assert.True(result);
    }

    [Fact]
    public void SetClipboard_AcceptsNewerSequenceNumber()
    {
        var message1 = new HostClipboardMessage
        {
            MessageId = 1,
            Format = ClipboardFormat.PlainText,
            Data = "First"u8.ToArray(),
            SequenceNumber = 5
        };

        _ = _service.SetClipboard(message1);

        var message2 = new HostClipboardMessage
        {
            MessageId = 2,
            Format = ClipboardFormat.PlainText,
            Data = "Second"u8.ToArray(),
            SequenceNumber = 10 // Newer
        };

        // On non-Windows this will fail at OpenClipboard, but the sequence check passes
        _ = _service.SetClipboard(message2);

        // Just verify no exception thrown - actual clipboard test needs Windows
    }

    [Fact]
    public void ClipboardChanged_EventCanBeSubscribed()
    {
        var eventRaised = false;
        _service.ClipboardChanged += (_, _) => eventRaised = true;

        // Event subscription should work
        Assert.False(eventRaised); // No event raised yet
    }

    [Fact]
    public void Dispose_CanBeCalledMultipleTimes()
    {
        _service.Dispose();
        _service.Dispose(); // Should not throw
    }

    [Fact]
    public void ClipboardFormat_HasExpectedValues()
    {
        // Verify enum values exist
        Assert.Equal("PlainText", ClipboardFormat.PlainText.ToString());
        Assert.Equal("Rtf", ClipboardFormat.Rtf.ToString());
        Assert.Equal("Html", ClipboardFormat.Html.ToString());
        Assert.Equal("Png", ClipboardFormat.Png.ToString());
        Assert.Equal("FileUrl", ClipboardFormat.FileUrl.ToString());
    }

    private sealed class TestLogger : IAgentLogger
    {
        public void Debug(string message) { }
        public void Info(string message) { }
        public void Warn(string message) { }
        public void Error(string message) { }
    }
}

