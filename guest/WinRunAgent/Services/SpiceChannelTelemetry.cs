using System.Diagnostics;
using System.Threading.Channels;

namespace WinRun.Agent.Services;

// MARK: - Retry Policy

/// <summary>
/// Policy for automatic retry attempts with exponential backoff.
/// Mirrors the host's ReconnectPolicy for consistent behavior.
/// </summary>
public sealed class RetryPolicy
{
    /// <summary>Initial delay before the first retry (in milliseconds).</summary>
    public int InitialDelayMs { get; init; } = 500;

    /// <summary>Multiplier applied to delay after each failed attempt.</summary>
    public double Multiplier { get; init; } = 1.8;

    /// <summary>Maximum delay cap (in milliseconds).</summary>
    public int MaxDelayMs { get; init; } = 15_000;

    /// <summary>Maximum number of retry attempts. Null means unlimited.</summary>
    public int? MaxAttempts { get; init; } = 5;

    /// <summary>Default policy for Spice channel message sends.</summary>
    public static RetryPolicy Default => new();

    /// <summary>Aggressive policy for critical messages (more retries, shorter delays).</summary>
    public static RetryPolicy Critical => new()
    {
        InitialDelayMs = 100,
        Multiplier = 1.5,
        MaxDelayMs = 5_000,
        MaxAttempts = 10
    };

    /// <summary>No retries - single attempt only.</summary>
    public static RetryPolicy NoRetry => new()
    {
        InitialDelayMs = 0,
        MaxAttempts = 1
    };

    /// <summary>
    /// Calculates the delay for a given retry attempt (1-indexed).
    /// </summary>
    /// <param name="attempt">The retry attempt number (1 for first retry).</param>
    /// <returns>Delay in milliseconds.</returns>
    public int GetDelayMs(int attempt)
    {
        if (attempt < 1)
        {
            return 0;
        }

        var exponent = Math.Pow(Multiplier, attempt - 1);
        var delay = (int)(InitialDelayMs * exponent);
        return Math.Min(delay, MaxDelayMs);
    }

    /// <summary>
    /// Checks whether another retry should be attempted.
    /// </summary>
    /// <param name="attempt">The current attempt number (0-indexed).</param>
    /// <returns>True if another attempt should be made.</returns>
    public bool ShouldRetry(int attempt) => MaxAttempts is null || attempt < MaxAttempts;
}

// MARK: - Telemetry Metrics

/// <summary>
/// Metrics counters for Spice channel operations.
/// Thread-safe via Interlocked operations.
/// </summary>
public sealed class SpiceChannelMetrics
{
    private long _sendAttempts;
    private long _sendSuccesses;
    private long _sendFailures;
    private long _sendRetries;
    private long _receiveAttempts;
    private long _receiveSuccesses;
    private long _receiveFailures;
    private long _messageProcessingErrors;
    private long _lastErrorTimestamp;
    private string? _lastErrorMessage;
    private readonly object _errorLock = new();

    /// <summary>Total number of send attempts (including retries).</summary>
    public long SendAttempts => Interlocked.Read(ref _sendAttempts);

    /// <summary>Number of successful sends.</summary>
    public long SendSuccesses => Interlocked.Read(ref _sendSuccesses);

    /// <summary>Number of failed sends (after all retries exhausted).</summary>
    public long SendFailures => Interlocked.Read(ref _sendFailures);

    /// <summary>Total number of retry attempts across all sends.</summary>
    public long SendRetries => Interlocked.Read(ref _sendRetries);

    /// <summary>Total number of receive attempts.</summary>
    public long ReceiveAttempts => Interlocked.Read(ref _receiveAttempts);

    /// <summary>Number of successful receives.</summary>
    public long ReceiveSuccesses => Interlocked.Read(ref _receiveSuccesses);

    /// <summary>Number of failed receives.</summary>
    public long ReceiveFailures => Interlocked.Read(ref _receiveFailures);

    /// <summary>Number of message processing errors.</summary>
    public long MessageProcessingErrors => Interlocked.Read(ref _messageProcessingErrors);

    /// <summary>Unix timestamp of the last error.</summary>
    public long LastErrorTimestamp => Interlocked.Read(ref _lastErrorTimestamp);

    /// <summary>Message from the most recent error.</summary>
    public string? LastErrorMessage
    {
        get { lock (_errorLock) { return _lastErrorMessage; } }
    }

    /// <summary>Send success rate as a percentage (0-100).</summary>
    public double SendSuccessRate
    {
        get
        {
            var total = SendSuccesses + SendFailures;
            return total == 0 ? 100.0 : SendSuccesses * 100.0 / total;
        }
    }

    /// <summary>Receive success rate as a percentage (0-100).</summary>
    public double ReceiveSuccessRate
    {
        get
        {
            var total = ReceiveSuccesses + ReceiveFailures;
            return total == 0 ? 100.0 : ReceiveSuccesses * 100.0 / total;
        }
    }

    public void RecordSendAttempt() => Interlocked.Increment(ref _sendAttempts);
    public void RecordSendSuccess() => Interlocked.Increment(ref _sendSuccesses);
    public void RecordSendFailure(string? errorMessage = null)
    {
        _ = Interlocked.Increment(ref _sendFailures);
        RecordError(errorMessage);
    }
    public void RecordSendRetry() => Interlocked.Increment(ref _sendRetries);

    public void RecordReceiveAttempt() => Interlocked.Increment(ref _receiveAttempts);
    public void RecordReceiveSuccess() => Interlocked.Increment(ref _receiveSuccesses);
    public void RecordReceiveFailure(string? errorMessage = null)
    {
        _ = Interlocked.Increment(ref _receiveFailures);
        RecordError(errorMessage);
    }

    public void RecordMessageProcessingError(string? errorMessage = null)
    {
        _ = Interlocked.Increment(ref _messageProcessingErrors);
        RecordError(errorMessage);
    }

    private void RecordError(string? message)
    {
        if (message is null)
        {
            return;
        }

        lock (_errorLock)
        {
            _lastErrorMessage = message;
            _ = Interlocked.Exchange(ref _lastErrorTimestamp, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        }
    }

    /// <summary>
    /// Creates a snapshot of the current metrics.
    /// </summary>
    public SpiceChannelMetricsSnapshot ToSnapshot() => new()
    {
        SendAttempts = SendAttempts,
        SendSuccesses = SendSuccesses,
        SendFailures = SendFailures,
        SendRetries = SendRetries,
        ReceiveAttempts = ReceiveAttempts,
        ReceiveSuccesses = ReceiveSuccesses,
        ReceiveFailures = ReceiveFailures,
        MessageProcessingErrors = MessageProcessingErrors,
        LastErrorTimestamp = LastErrorTimestamp,
        LastErrorMessage = LastErrorMessage,
        Timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
    };

    /// <summary>
    /// Resets all metrics to zero.
    /// </summary>
    public void Reset()
    {
        _ = Interlocked.Exchange(ref _sendAttempts, 0);
        _ = Interlocked.Exchange(ref _sendSuccesses, 0);
        _ = Interlocked.Exchange(ref _sendFailures, 0);
        _ = Interlocked.Exchange(ref _sendRetries, 0);
        _ = Interlocked.Exchange(ref _receiveAttempts, 0);
        _ = Interlocked.Exchange(ref _receiveSuccesses, 0);
        _ = Interlocked.Exchange(ref _receiveFailures, 0);
        _ = Interlocked.Exchange(ref _messageProcessingErrors, 0);
        _ = Interlocked.Exchange(ref _lastErrorTimestamp, 0);
        lock (_errorLock)
        { _lastErrorMessage = null; }
    }
}

/// <summary>
/// Immutable snapshot of channel metrics for reporting.
/// </summary>
public sealed record SpiceChannelMetricsSnapshot
{
    public long SendAttempts { get; init; }
    public long SendSuccesses { get; init; }
    public long SendFailures { get; init; }
    public long SendRetries { get; init; }
    public long ReceiveAttempts { get; init; }
    public long ReceiveSuccesses { get; init; }
    public long ReceiveFailures { get; init; }
    public long MessageProcessingErrors { get; init; }
    public long LastErrorTimestamp { get; init; }
    public string? LastErrorMessage { get; init; }
    public long Timestamp { get; init; }
}

// MARK: - Spice Channel Telemetry

/// <summary>
/// Manages telemetry collection and reporting for Spice channel operations.
/// Provides retry logic and failure tracking for reliable message delivery.
/// </summary>
public sealed class SpiceChannelTelemetry : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly Channel<GuestMessage>? _outboundChannel;
    private readonly RetryPolicy _defaultRetryPolicy;
    private readonly Timer? _reportTimer;
    private readonly TimeSpan _reportInterval;
    private readonly Stopwatch _uptime;
    private bool _disposed;

    /// <summary>Gets the current channel metrics.</summary>
    public SpiceChannelMetrics Metrics { get; }

    /// <summary>Gets the agent uptime.</summary>
    public TimeSpan Uptime => _uptime.Elapsed;

    /// <summary>
    /// Creates a new SpiceChannelTelemetry instance.
    /// </summary>
    /// <param name="logger">Logger for telemetry events.</param>
    /// <param name="outboundChannel">Optional channel for sending telemetry reports to host.</param>
    /// <param name="defaultRetryPolicy">Default retry policy for sends. Uses RetryPolicy.Default if null.</param>
    /// <param name="reportInterval">Interval for automatic telemetry reporting. Null to disable.</param>
    public SpiceChannelTelemetry(
        IAgentLogger logger,
        Channel<GuestMessage>? outboundChannel = null,
        RetryPolicy? defaultRetryPolicy = null,
        TimeSpan? reportInterval = null)
    {
        _logger = logger;
        Metrics = new SpiceChannelMetrics();
        _outboundChannel = outboundChannel;
        _defaultRetryPolicy = defaultRetryPolicy ?? RetryPolicy.Default;
        _reportInterval = reportInterval ?? TimeSpan.FromMinutes(5);
        _uptime = Stopwatch.StartNew();

        // Set up periodic telemetry reporting if enabled and channel is available
        if (_outboundChannel is not null && _reportInterval > TimeSpan.Zero)
        {
            _reportTimer = new Timer(
                _ => _ = ReportTelemetryAsync(),
                null,
                _reportInterval,
                _reportInterval);
        }
    }

    /// <summary>
    /// Sends a message with retry logic using the specified policy.
    /// </summary>
    /// <typeparam name="T">The message type.</typeparam>
    /// <param name="channel">The channel to write to.</param>
    /// <param name="message">The message to send.</param>
    /// <param name="policy">Retry policy. Uses default if null.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>True if the message was sent successfully, false otherwise.</returns>
    public async Task<bool> SendWithRetryAsync<T>(
        ChannelWriter<T> channel,
        T message,
        RetryPolicy? policy = null,
        CancellationToken cancellationToken = default)
    {
        policy ??= _defaultRetryPolicy;
        var attempt = 0;
        var messageTypeName = typeof(T).Name;

        while (policy.ShouldRetry(attempt))
        {
            try
            {
                Metrics.RecordSendAttempt();

                // Apply delay for retries (not first attempt)
                if (attempt > 0)
                {
                    Metrics.RecordSendRetry();
                    var delayMs = policy.GetDelayMs(attempt);
                    _logger.Debug($"Retrying send (attempt {attempt + 1}), waiting {delayMs}ms", new LogMetadata
                    {
                        ["message_type"] = messageTypeName,
                        ["attempt"] = attempt + 1,
                        ["delay_ms"] = delayMs
                    });
                    await Task.Delay(delayMs, cancellationToken);
                }

                await channel.WriteAsync(message, cancellationToken);
                Metrics.RecordSendSuccess();

                if (attempt > 0)
                {
                    _logger.Info($"Send succeeded after {attempt + 1} attempts", new LogMetadata
                    {
                        ["message_type"] = messageTypeName,
                        ["total_attempts"] = attempt + 1
                    });
                }

                return true;
            }
            catch (TaskCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                // TaskCanceledException is thrown by WriteAsync when token is cancelled
                // Convert to OperationCanceledException for consistency
                _logger.Debug($"Send cancelled for {messageTypeName}");
                throw new OperationCanceledException("Send operation was cancelled", cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                // Cancellation is not a failure - don't record as failure
                _logger.Debug($"Send cancelled for {messageTypeName}");
                throw;
            }
            catch (ChannelClosedException ex)
            {
                // Channel is closed - no point retrying
                var errorMessage = $"Channel closed: {ex.Message}";
                Metrics.RecordSendFailure(errorMessage);
                _logger.Error($"Send failed - channel closed", new LogMetadata
                {
                    ["message_type"] = messageTypeName,
                    ["error"] = ex.Message
                });
                return false;
            }
            catch (Exception ex)
            {
                _logger.Warn($"Send attempt {attempt + 1} failed: {ex.Message}", new LogMetadata
                {
                    ["message_type"] = messageTypeName,
                    ["attempt"] = attempt + 1,
                    ["error"] = ex.Message
                });

                attempt++;

                // If we've exhausted retries, record the failure
                if (!policy.ShouldRetry(attempt))
                {
                    var errorMessage = $"Send failed after {attempt} attempts: {ex.Message}";
                    Metrics.RecordSendFailure(errorMessage);
                    _logger.Error($"Send failed after {attempt} attempts", new LogMetadata
                    {
                        ["message_type"] = messageTypeName,
                        ["total_attempts"] = attempt,
                        ["final_error"] = ex.Message
                    });
                    return false;
                }
            }
        }

        return false;
    }

    /// <summary>
    /// Records a successful message receive.
    /// </summary>
    public void RecordReceiveSuccess() => Metrics.RecordReceiveSuccess();

    /// <summary>
    /// Records a failed message receive.
    /// </summary>
    /// <param name="errorMessage">Error description.</param>
    public void RecordReceiveFailure(string? errorMessage = null) => Metrics.RecordReceiveFailure(errorMessage);

    /// <summary>
    /// Records a message processing error.
    /// </summary>
    /// <param name="errorMessage">Error description.</param>
    public void RecordMessageProcessingError(string? errorMessage = null) => Metrics.RecordMessageProcessingError(errorMessage);

    /// <summary>
    /// Reports current telemetry metrics to the host.
    /// </summary>
    public async Task ReportTelemetryAsync()
    {
        if (_outboundChannel is null || _disposed)
        {
            return;
        }

        var snapshot = Metrics.ToSnapshot();
        var telemetryMessage = new TelemetryReportMessage
        {
            UptimeMs = (long)Uptime.TotalMilliseconds,
            SendAttempts = snapshot.SendAttempts,
            SendSuccesses = snapshot.SendSuccesses,
            SendFailures = snapshot.SendFailures,
            SendRetries = snapshot.SendRetries,
            ReceiveFailures = snapshot.ReceiveFailures,
            MessageProcessingErrors = snapshot.MessageProcessingErrors,
            LastErrorTimestamp = snapshot.LastErrorTimestamp,
            LastErrorMessage = snapshot.LastErrorMessage
        };

        try
        {
            // Use a shorter retry policy for telemetry (non-critical)
            var telemetryPolicy = new RetryPolicy
            {
                InitialDelayMs = 100,
                MaxAttempts = 2
            };

            _ = await SendWithRetryAsync(_outboundChannel.Writer, telemetryMessage, telemetryPolicy);
            _logger.Debug("Telemetry report sent", new LogMetadata
            {
                ["send_success_rate"] = $"{snapshot.SendSuccesses * 100.0 / Math.Max(1, snapshot.SendSuccesses + snapshot.SendFailures):F1}%",
                ["total_errors"] = snapshot.SendFailures + snapshot.ReceiveFailures + snapshot.MessageProcessingErrors
            });
        }
        catch (Exception ex)
        {
            _logger.Warn($"Failed to send telemetry report: {ex.Message}");
        }
    }

    /// <summary>
    /// Creates a log metadata object with current telemetry stats.
    /// </summary>
    public LogMetadata GetTelemetryMetadata() => new()
    {
        ["uptime_ms"] = (long)Uptime.TotalMilliseconds,
        ["send_attempts"] = Metrics.SendAttempts,
        ["send_successes"] = Metrics.SendSuccesses,
        ["send_failures"] = Metrics.SendFailures,
        ["send_retries"] = Metrics.SendRetries,
        ["receive_failures"] = Metrics.ReceiveFailures,
        ["processing_errors"] = Metrics.MessageProcessingErrors
    };

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _reportTimer?.Dispose();
        _uptime.Stop();
    }
}

// MARK: - Telemetry Message

/// <summary>
/// Telemetry report message sent to host with channel health metrics.
/// </summary>
public sealed record TelemetryReportMessage : GuestMessage
{
    /// <summary>Agent uptime in milliseconds.</summary>
    public long UptimeMs { get; init; }

    /// <summary>Total send attempts.</summary>
    public long SendAttempts { get; init; }

    /// <summary>Successful sends.</summary>
    public long SendSuccesses { get; init; }

    /// <summary>Failed sends (after retries exhausted).</summary>
    public long SendFailures { get; init; }

    /// <summary>Total retry attempts.</summary>
    public long SendRetries { get; init; }

    /// <summary>Failed receives.</summary>
    public long ReceiveFailures { get; init; }

    /// <summary>Message processing errors.</summary>
    public long MessageProcessingErrors { get; init; }

    /// <summary>Timestamp of last error (Unix ms).</summary>
    public long LastErrorTimestamp { get; init; }

    /// <summary>Most recent error message.</summary>
    public string? LastErrorMessage { get; init; }
}
