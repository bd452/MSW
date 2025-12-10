using System.Threading.Channels;
using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class RetryPolicyTests
{
    [Fact]
    public void Default_HasExpectedValues()
    {
        var policy = RetryPolicy.Default;

        Assert.Equal(500, policy.InitialDelayMs);
        Assert.Equal(1.8, policy.Multiplier);
        Assert.Equal(15_000, policy.MaxDelayMs);
        Assert.Equal(5, policy.MaxAttempts);
    }

    [Fact]
    public void Critical_HasMoreRetriesAndShorterDelays()
    {
        var policy = RetryPolicy.Critical;

        Assert.Equal(100, policy.InitialDelayMs);
        Assert.Equal(1.5, policy.Multiplier);
        Assert.Equal(5_000, policy.MaxDelayMs);
        Assert.Equal(10, policy.MaxAttempts);
    }

    [Fact]
    public void NoRetry_HasSingleAttempt()
    {
        var policy = RetryPolicy.NoRetry;

        Assert.Equal(1, policy.MaxAttempts);
    }

    [Theory]
    [InlineData(1, 500)]   // First retry: 500ms
    [InlineData(2, 900)]   // Second retry: 500 * 1.8 = 900ms
    [InlineData(3, 1620)]  // Third retry: 500 * 1.8^2 = 1620ms
    public void GetDelayMs_CalculatesExponentialBackoff(int attempt, int expectedDelay)
    {
        var policy = RetryPolicy.Default;

        var delay = policy.GetDelayMs(attempt);

        Assert.Equal(expectedDelay, delay);
    }

    [Fact]
    public void GetDelayMs_CapsAtMaxDelay()
    {
        var policy = new RetryPolicy
        {
            InitialDelayMs = 1000,
            Multiplier = 10,
            MaxDelayMs = 5000
        };

        // 1000 * 10 = 10000, but should be capped at 5000
        var delay = policy.GetDelayMs(2);

        Assert.Equal(5000, delay);
    }

    [Fact]
    public void GetDelayMs_ReturnsZeroForInvalidAttempt()
    {
        var policy = RetryPolicy.Default;

        Assert.Equal(0, policy.GetDelayMs(0));
        Assert.Equal(0, policy.GetDelayMs(-1));
    }

    [Fact]
    public void ShouldRetry_ReturnsTrueWithinLimit()
    {
        var policy = new RetryPolicy { MaxAttempts = 3 };

        Assert.True(policy.ShouldRetry(0));
        Assert.True(policy.ShouldRetry(1));
        Assert.True(policy.ShouldRetry(2));
        Assert.False(policy.ShouldRetry(3));
    }

    [Fact]
    public void ShouldRetry_AlwaysTrueWhenUnlimited()
    {
        var policy = new RetryPolicy { MaxAttempts = null };

        Assert.True(policy.ShouldRetry(0));
        Assert.True(policy.ShouldRetry(100));
        Assert.True(policy.ShouldRetry(1000));
    }
}

public sealed class SpiceChannelMetricsTests
{
    [Fact]
    public void NewMetrics_HasZeroValues()
    {
        var metrics = new SpiceChannelMetrics();

        Assert.Equal(0, metrics.SendAttempts);
        Assert.Equal(0, metrics.SendSuccesses);
        Assert.Equal(0, metrics.SendFailures);
        Assert.Equal(0, metrics.SendRetries);
        Assert.Equal(0, metrics.ReceiveAttempts);
        Assert.Equal(0, metrics.ReceiveSuccesses);
        Assert.Equal(0, metrics.ReceiveFailures);
        Assert.Equal(0, metrics.MessageProcessingErrors);
    }

    [Fact]
    public void RecordSend_IncrementsCounters()
    {
        var metrics = new SpiceChannelMetrics();

        metrics.RecordSendAttempt();
        metrics.RecordSendAttempt();
        metrics.RecordSendSuccess();
        metrics.RecordSendFailure("test error");
        metrics.RecordSendRetry();

        Assert.Equal(2, metrics.SendAttempts);
        Assert.Equal(1, metrics.SendSuccesses);
        Assert.Equal(1, metrics.SendFailures);
        Assert.Equal(1, metrics.SendRetries);
    }

    [Fact]
    public void RecordReceive_IncrementsCounters()
    {
        var metrics = new SpiceChannelMetrics();

        metrics.RecordReceiveAttempt();
        metrics.RecordReceiveSuccess();
        metrics.RecordReceiveAttempt();
        metrics.RecordReceiveFailure("error");

        Assert.Equal(2, metrics.ReceiveAttempts);
        Assert.Equal(1, metrics.ReceiveSuccesses);
        Assert.Equal(1, metrics.ReceiveFailures);
    }

    [Fact]
    public void RecordMessageProcessingError_IncrementsAndTracksError()
    {
        var metrics = new SpiceChannelMetrics();

        metrics.RecordMessageProcessingError("handler failed");

        Assert.Equal(1, metrics.MessageProcessingErrors);
        Assert.Equal("handler failed", metrics.LastErrorMessage);
        Assert.True(metrics.LastErrorTimestamp > 0);
    }

    [Fact]
    public void SendSuccessRate_CalculatesCorrectly()
    {
        var metrics = new SpiceChannelMetrics();

        // No sends yet - should be 100%
        Assert.Equal(100.0, metrics.SendSuccessRate);

        // 3 successes, 1 failure = 75%
        metrics.RecordSendSuccess();
        metrics.RecordSendSuccess();
        metrics.RecordSendSuccess();
        metrics.RecordSendFailure();

        Assert.Equal(75.0, metrics.SendSuccessRate);
    }

    [Fact]
    public void ReceiveSuccessRate_CalculatesCorrectly()
    {
        var metrics = new SpiceChannelMetrics();

        // No receives yet - should be 100%
        Assert.Equal(100.0, metrics.ReceiveSuccessRate);

        // 1 success, 1 failure = 50%
        metrics.RecordReceiveSuccess();
        metrics.RecordReceiveFailure();

        Assert.Equal(50.0, metrics.ReceiveSuccessRate);
    }

    [Fact]
    public void ToSnapshot_CreatesImmutableCopy()
    {
        var metrics = new SpiceChannelMetrics();
        metrics.RecordSendSuccess();
        metrics.RecordReceiveFailure("test");

        var snapshot = metrics.ToSnapshot();

        // Modify metrics after snapshot
        metrics.RecordSendSuccess();

        // Snapshot should be unchanged
        Assert.Equal(1, snapshot.SendSuccesses);
        Assert.Equal(2, metrics.SendSuccesses);
        Assert.Equal(1, snapshot.ReceiveFailures);
        Assert.Equal("test", snapshot.LastErrorMessage);
    }

    [Fact]
    public void Reset_ClearsAllCounters()
    {
        var metrics = new SpiceChannelMetrics();
        metrics.RecordSendAttempt();
        metrics.RecordSendSuccess();
        metrics.RecordReceiveFailure("error");
        metrics.RecordMessageProcessingError("error");

        metrics.Reset();

        Assert.Equal(0, metrics.SendAttempts);
        Assert.Equal(0, metrics.SendSuccesses);
        Assert.Equal(0, metrics.ReceiveFailures);
        Assert.Equal(0, metrics.MessageProcessingErrors);
        Assert.Null(metrics.LastErrorMessage);
        Assert.Equal(0, metrics.LastErrorTimestamp);
    }

    [Fact]
    public void Metrics_AreThreadSafe()
    {
        var metrics = new SpiceChannelMetrics();
        var iterations = 1000;

        // Parallel increments
        _ = Parallel.For(0, iterations, _ =>
        {
            metrics.RecordSendAttempt();
            metrics.RecordSendSuccess();
        });

        Assert.Equal(iterations, metrics.SendAttempts);
        Assert.Equal(iterations, metrics.SendSuccesses);
    }
}

public sealed class SpiceChannelTelemetryTests : IDisposable
{
    private readonly TestLogger _logger = new();

    public void Dispose() { }

    [Fact]
    public async Task SendWithRetryAsync_SucceedsOnFirstAttempt()
    {
        var channel = Channel.CreateUnbounded<string>();
        using var telemetry = new SpiceChannelTelemetry(_logger);

        var result = await telemetry.SendWithRetryAsync(channel.Writer, "test message");

        Assert.True(result);
        Assert.Equal(1, telemetry.Metrics.SendAttempts);
        Assert.Equal(1, telemetry.Metrics.SendSuccesses);
        Assert.Equal(0, telemetry.Metrics.SendFailures);
        Assert.Equal(0, telemetry.Metrics.SendRetries);

        // Verify message was written
        Assert.True(channel.Reader.TryRead(out var msg));
        Assert.Equal("test message", msg);
    }

    [Fact]
    public async Task SendWithRetryAsync_FailsWhenChannelClosed()
    {
        var channel = Channel.CreateUnbounded<string>();
        channel.Writer.Complete();
        using var telemetry = new SpiceChannelTelemetry(_logger);

        var result = await telemetry.SendWithRetryAsync(
            channel.Writer,
            "test",
            RetryPolicy.NoRetry);

        Assert.False(result);
        Assert.Equal(1, telemetry.Metrics.SendAttempts);
        Assert.Equal(0, telemetry.Metrics.SendSuccesses);
        Assert.Equal(1, telemetry.Metrics.SendFailures);
    }

    [Fact]
    public async Task SendWithRetryAsync_RespectsNoRetryPolicy()
    {
        var channel = Channel.CreateBounded<string>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.Wait
        });

        // Fill the channel
        await channel.Writer.WriteAsync("blocking");

        using var telemetry = new SpiceChannelTelemetry(_logger);
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));

        try
        {
            _ = await telemetry.SendWithRetryAsync(
                channel.Writer,
                "test",
                RetryPolicy.NoRetry,
                cts.Token);
        }
        catch (OperationCanceledException)
        {
            // Expected - write blocked and was cancelled
        }

        // Should only have one attempt with NoRetry
        Assert.Equal(1, telemetry.Metrics.SendAttempts);
        Assert.Equal(0, telemetry.Metrics.SendRetries);
    }

    [Fact]
    public async Task SendWithRetryAsync_ThrowsOnCancellation()
    {
        var channel = Channel.CreateBounded<string>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.Wait
        });
        await channel.Writer.WriteAsync("blocking");

        using var telemetry = new SpiceChannelTelemetry(_logger);
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        _ = await Assert.ThrowsAsync<OperationCanceledException>(() =>
            telemetry.SendWithRetryAsync(channel.Writer, "test", cancellationToken: cts.Token));
    }

    [Fact]
    public void RecordReceiveSuccess_IncrementsMetrics()
    {
        using var telemetry = new SpiceChannelTelemetry(_logger);

        telemetry.RecordReceiveSuccess();
        telemetry.RecordReceiveSuccess();

        Assert.Equal(2, telemetry.Metrics.ReceiveSuccesses);
    }

    [Fact]
    public void RecordReceiveFailure_IncrementsMetricsAndTracksError()
    {
        using var telemetry = new SpiceChannelTelemetry(_logger);

        telemetry.RecordReceiveFailure("network error");

        Assert.Equal(1, telemetry.Metrics.ReceiveFailures);
        Assert.Equal("network error", telemetry.Metrics.LastErrorMessage);
    }

    [Fact]
    public void RecordMessageProcessingError_IncrementsMetrics()
    {
        using var telemetry = new SpiceChannelTelemetry(_logger);

        telemetry.RecordMessageProcessingError("handler threw");

        Assert.Equal(1, telemetry.Metrics.MessageProcessingErrors);
    }

    [Fact]
    public void GetTelemetryMetadata_ReturnsCurrentStats()
    {
        using var telemetry = new SpiceChannelTelemetry(_logger);
        telemetry.RecordReceiveSuccess();
        telemetry.RecordReceiveFailure("err");

        var metadata = telemetry.GetTelemetryMetadata();

        Assert.Contains("uptime_ms", metadata.Keys);
        Assert.Contains("send_attempts", metadata.Keys);
        Assert.Contains("receive_failures", metadata.Keys);
        Assert.Equal(1L, metadata["receive_failures"]);
    }

    [Fact]
    public void Uptime_TracksElapsedTime()
    {
        using var telemetry = new SpiceChannelTelemetry(_logger);

        Thread.Sleep(10);

        Assert.True(telemetry.Uptime.TotalMilliseconds >= 10);
    }

    [Fact]
    public async Task ReportTelemetryAsync_SendsMessageToChannel()
    {
        var outbound = Channel.CreateUnbounded<GuestMessage>();
        using var telemetry = new SpiceChannelTelemetry(_logger, outbound);

        // Record some activity and ensure some time has passed
        telemetry.RecordReceiveSuccess();
        telemetry.RecordMessageProcessingError("test error");
        await Task.Delay(10); // Ensure some uptime has elapsed

        await telemetry.ReportTelemetryAsync();

        // Wait for message with timeout
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var message = await outbound.Reader.ReadAsync(cts.Token);
        var report = Assert.IsType<TelemetryReportMessage>(message);
        Assert.True(report.UptimeMs >= 0); // Uptime should be non-negative
        Assert.Equal(1, report.MessageProcessingErrors);
        Assert.Equal("test error", report.LastErrorMessage);
    }

    [Fact]
    public async Task ReportTelemetryAsync_DoesNothingWithoutChannel()
    {
        using var telemetry = new SpiceChannelTelemetry(_logger, outboundChannel: null);

        // Should not throw
        await telemetry.ReportTelemetryAsync();
    }
}

public sealed class TelemetryReportMessageTests
{
    [Fact]
    public void TelemetryReportMessage_HasTimestamp()
    {
        var before = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var message = new TelemetryReportMessage
        {
            UptimeMs = 1000,
            SendAttempts = 10
        };
        var after = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        Assert.InRange(message.Timestamp, before, after);
    }

    [Fact]
    public void TelemetryReportMessage_SerializesCorrectly()
    {
        var message = new TelemetryReportMessage
        {
            UptimeMs = 60000,
            SendAttempts = 100,
            SendSuccesses = 95,
            SendFailures = 5,
            SendRetries = 10,
            ReceiveFailures = 2,
            MessageProcessingErrors = 1,
            LastErrorTimestamp = 12345678,
            LastErrorMessage = "test error"
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        // Verify it serializes without error and has content
        Assert.NotEmpty(bytes);
        Assert.True(bytes.Length > 5); // Header + payload
        Assert.Equal((byte)SpiceMessageType.TelemetryReport, bytes[0]);
    }
}
