using System.Threading.Channels;

namespace WinRun.Agent.Services;

/// <summary>
/// Configuration for the frame streaming service.
/// </summary>
public sealed record FrameStreamingConfig
{
    /// <summary>Target frames per second for capture loop.</summary>
    public int TargetFps { get; init; } = 30;

    /// <summary>Timeout in milliseconds for waiting on new frames from Desktop Duplication.</summary>
    public int CaptureTimeoutMs { get; init; } = 100;

    /// <summary>Maximum consecutive capture failures before attempting reinitialization.</summary>
    public int MaxConsecutiveFailures { get; init; } = 10;

    /// <summary>Delay before reinitializing after failures (milliseconds).</summary>
    public int ReinitializationDelayMs { get; init; } = 1000;

    /// <summary>Whether to enable per-window frame extraction (vs full desktop).</summary>
    public bool EnablePerWindowCapture { get; init; } = true;

    /// <summary>Minimum interval between frames for the same window (milliseconds).</summary>
    public int MinWindowFrameIntervalMs { get; init; } = 33; // ~30fps per window

    /// <summary>Configuration for frame compression. Null to disable compression.</summary>
    public FrameCompressionConfig? Compression { get; init; } = new();

    /// <summary>Computed target frame interval in milliseconds.</summary>
    public int TargetFrameIntervalMs => 1000 / TargetFps;
}

/// <summary>
/// Service that orchestrates capturing desktop/window frames and streaming them
/// to the host via shared memory with FrameReady notifications.
/// </summary>
public sealed class FrameStreamingService : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly WindowTracker _windowTracker;
    private readonly DesktopDuplicationBridge _desktopDuplication;
    private readonly SharedFrameBufferWriter _frameBufferWriter;
    private readonly ChannelWriter<GuestMessage> _outboundWriter;
    private readonly FrameStreamingConfig _config;
    private readonly FrameCompressor? _compressor;

    private readonly Dictionary<ulong, WindowFrameState> _windowFrameStates = [];
    private readonly object _stateLock = new();

    private CancellationTokenSource? _cts;
    private Task? _captureTask;
    private uint _frameCounter;
    private int _consecutiveFailures;
    private bool _disposed;

    /// <summary>
    /// Creates a new FrameStreamingService.
    /// </summary>
    /// <param name="logger">Logger for diagnostics.</param>
    /// <param name="windowTracker">Window tracker for per-window capture.</param>
    /// <param name="desktopDuplication">Desktop duplication bridge for frame capture.</param>
    /// <param name="frameBufferWriter">Shared memory writer for frame data.</param>
    /// <param name="outboundChannel">Channel for sending FrameReady notifications to host.</param>
    /// <param name="config">Optional configuration settings.</param>
    public FrameStreamingService(
        IAgentLogger logger,
        WindowTracker windowTracker,
        DesktopDuplicationBridge desktopDuplication,
        SharedFrameBufferWriter frameBufferWriter,
        Channel<GuestMessage> outboundChannel,
        FrameStreamingConfig? config = null)
    {
        _logger = logger;
        _windowTracker = windowTracker;
        _desktopDuplication = desktopDuplication;
        _frameBufferWriter = frameBufferWriter;
        _outboundWriter = outboundChannel.Writer;
        _config = config ?? new FrameStreamingConfig();

        // Initialize compressor if compression is configured
        if (_config.Compression is { Enabled: true })
        {
            _compressor = new FrameCompressor(logger, _config.Compression);
            _logger.Info($"Frame compression enabled: level={_config.Compression.CompressionLevel}");
        }
    }

    /// <summary>
    /// Gets whether the capture loop is currently running.
    /// </summary>
    public bool IsRunning => _captureTask is { IsCompleted: false };

    /// <summary>
    /// Gets the total number of frames captured.
    /// </summary>
    public uint TotalFramesCaptured => _frameCounter;

    /// <summary>
    /// Gets capture statistics for diagnostics.
    /// </summary>
    public FrameStreamingStats Stats { get; } = new();

    /// <summary>
    /// Gets compression statistics (null if compression is disabled).
    /// </summary>
    public CompressionStats? CompressionStats => _compressor?.Stats;

    /// <summary>
    /// Starts the frame capture loop.
    /// </summary>
    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (IsRunning)
        {
            _logger.Warn("Frame streaming already running");
            return;
        }

        _logger.Info($"Starting frame streaming at {_config.TargetFps} FPS target");

        _cts = new CancellationTokenSource();
        _captureTask = RunCaptureLoopAsync(_cts.Token);
    }

    /// <summary>
    /// Stops the frame capture loop.
    /// </summary>
    public async Task StopAsync()
    {
        if (_cts == null || _captureTask == null)
        {
            return;
        }

        _logger.Info("Stopping frame streaming");

        await _cts.CancelAsync();

        try
        {
            await _captureTask.WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (TimeoutException)
        {
            _logger.Warn("Frame capture loop did not stop within timeout");
        }
        catch (OperationCanceledException)
        {
            // Expected
        }

        _cts.Dispose();
        _cts = null;
        _captureTask = null;

        _logger.Info($"Frame streaming stopped. Total frames: {_frameCounter}");
    }

    private async Task RunCaptureLoopAsync(CancellationToken token)
    {
        _logger.Debug("Frame capture loop starting");

        // Initialize desktop duplication
        if (!await TryInitializeDesktopDuplicationAsync(token))
        {
            _logger.Error("Failed to initialize desktop duplication, capture loop exiting");
            return;
        }

        // Set guest active flag
        _frameBufferWriter.SetGuestActive(true);

        var targetInterval = TimeSpan.FromMilliseconds(_config.TargetFrameIntervalMs);

        try
        {
            while (!token.IsCancellationRequested)
            {
                var frameStart = DateTime.UtcNow;

                try
                {
                    await CaptureAndStreamFrameAsync(token);
                    _consecutiveFailures = 0;
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex)
                {
                    _consecutiveFailures++;
                    Stats.RecordCaptureError();
                    _logger.Error($"Frame capture error ({_consecutiveFailures}/{_config.MaxConsecutiveFailures}): {ex.Message}");

                    if (_consecutiveFailures >= _config.MaxConsecutiveFailures)
                    {
                        _logger.Warn("Too many consecutive failures, attempting reinitialization");
                        await ReinitializeDesktopDuplicationAsync(token);
                        _consecutiveFailures = 0;
                    }
                }

                // Maintain target frame rate
                var elapsed = DateTime.UtcNow - frameStart;
                var delay = targetInterval - elapsed;
                if (delay > TimeSpan.Zero)
                {
                    await Task.Delay(delay, token);
                }
            }
        }
        finally
        {
            _frameBufferWriter.SetGuestActive(false);
            _logger.Debug("Frame capture loop ended");
        }
    }

    private async Task<bool> TryInitializeDesktopDuplicationAsync(CancellationToken token)
    {
        const int maxAttempts = 3;

        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            if (token.IsCancellationRequested)
            {
                return false;
            }

            if (_desktopDuplication.Initialize())
            {
                _logger.Info($"Desktop duplication initialized: {_desktopDuplication.OutputWidth}x{_desktopDuplication.OutputHeight}");
                return true;
            }

            _logger.Warn($"Desktop duplication init attempt {attempt}/{maxAttempts} failed");

            if (attempt < maxAttempts)
            {
                await Task.Delay(500 * attempt, token);
            }
        }

        return false;
    }

    private async Task ReinitializeDesktopDuplicationAsync(CancellationToken token)
    {
        _logger.Info("Reinitializing desktop duplication");

        // Wait before reinitializing
        await Task.Delay(_config.ReinitializationDelayMs, token);

        // Dispose and recreate is handled by Initialize() which cleans up if needed
        if (!await TryInitializeDesktopDuplicationAsync(token))
        {
            _logger.Error("Failed to reinitialize desktop duplication");
        }
    }

    private async Task CaptureAndStreamFrameAsync(CancellationToken token)
    {
        Stats.RecordCaptureAttempt();

        // Capture full desktop frame
        var frame = _desktopDuplication.CaptureFrame(_config.CaptureTimeoutMs);
        if (frame == null)
        {
            // No new frame available - this is normal when screen is static
            return;
        }

        Stats.RecordFrameCaptured();

        if (_config.EnablePerWindowCapture)
        {
            // Stream individual window frames
            await StreamPerWindowFramesAsync(frame, token);
        }
        else
        {
            // Stream full desktop frame
            await StreamFullDesktopFrameAsync(frame, token);
        }
    }

    private async Task StreamPerWindowFramesAsync(CapturedFrame desktopFrame, CancellationToken token)
    {
        var trackedWindows = _windowTracker.TrackedWindows;
        var now = DateTime.UtcNow;

        foreach (var (hwnd, metadata) in trackedWindows)
        {
            if (token.IsCancellationRequested)
            {
                break;
            }

            // Skip minimized windows
            if (metadata.IsMinimized)
            {
                continue;
            }

            var windowId = (ulong)hwnd;

            // Check if enough time has passed since last frame for this window
            if (!ShouldCaptureWindow(windowId, now))
            {
                continue;
            }

            // Extract window region from desktop frame
            var windowFrame = DesktopDuplicationBridge.ExtractWindowRegion(desktopFrame, metadata.Bounds);
            if (windowFrame == null)
            {
                continue;
            }

            // Write to shared memory and notify host
            await WriteFrameAndNotifyAsync(windowId, windowFrame, token);

            // Update window frame state
            UpdateWindowFrameState(windowId, now);
        }
    }

    private async Task StreamFullDesktopFrameAsync(CapturedFrame frame, CancellationToken token)
    {
        // Use window ID 0 for full desktop
        const ulong desktopWindowId = 0;
        await WriteFrameAndNotifyAsync(desktopWindowId, frame, token);
    }

    private async Task WriteFrameAndNotifyAsync(ulong windowId, CapturedFrame frame, CancellationToken token)
    {
        var frameNumber = Interlocked.Increment(ref _frameCounter);

        // Compress frame data if compression is enabled
        ReadOnlySpan<byte> dataToWrite;
        var isCompressed = false;

        if (_compressor != null)
        {
            var compressionResult = _compressor.Compress(frame.Data);
            dataToWrite = compressionResult.Data;
            isCompressed = compressionResult.IsCompressed;

            if (compressionResult.IsCompressed)
            {
                Stats.RecordFrameCompressed(compressionResult.BytesSaved);
            }
        }
        else
        {
            dataToWrite = frame.Data;
        }

        // Write frame to shared memory
        var slotIndex = _frameBufferWriter.WriteFrame(
            windowId,
            frameNumber,
            frame.Width,
            frame.Height,
            frame.Stride,
            frame.Format,
            dataToWrite,
            isCompressed);

        if (slotIndex < 0)
        {
            Stats.RecordBufferFull();
            _logger.Debug($"Shared buffer full, dropping frame {frameNumber} for window {windowId}");
            return;
        }

        Stats.RecordFrameWritten();

        // Send FrameReady notification to host
        var notification = new FrameReadyMessage
        {
            WindowId = windowId,
            SlotIndex = (uint)slotIndex,
            FrameNumber = frameNumber,
            IsKeyFrame = true // All frames are key frames until delta compression is implemented
        };

        try
        {
            await _outboundWriter.WriteAsync(notification, token);
            Stats.RecordNotificationSent();
        }
        catch (ChannelClosedException)
        {
            _logger.Warn("Outbound channel closed, cannot send frame notification");
        }
    }

    private bool ShouldCaptureWindow(ulong windowId, DateTime now)
    {
        lock (_stateLock)
        {
            if (!_windowFrameStates.TryGetValue(windowId, out var state))
            {
                return true; // First frame for this window
            }

            var elapsed = (now - state.LastCaptureTime).TotalMilliseconds;
            return elapsed >= _config.MinWindowFrameIntervalMs;
        }
    }

    private void UpdateWindowFrameState(ulong windowId, DateTime captureTime)
    {
        lock (_stateLock)
        {
            if (_windowFrameStates.TryGetValue(windowId, out var existing))
            {
                _windowFrameStates[windowId] = existing with
                {
                    LastCaptureTime = captureTime,
                    FrameCount = existing.FrameCount + 1
                };
            }
            else
            {
                _windowFrameStates[windowId] = new WindowFrameState
                {
                    WindowId = windowId,
                    LastCaptureTime = captureTime,
                    FrameCount = 1
                };
            }
        }
    }

    /// <summary>
    /// Cleans up tracking state for windows that no longer exist.
    /// Called periodically or when windows are destroyed.
    /// </summary>
    public void CleanupStaleWindowStates()
    {
        var activeWindowIds = _windowTracker.TrackedWindows.Keys
            .Select(hwnd => (ulong)hwnd)
            .ToHashSet();

        lock (_stateLock)
        {
            var staleIds = _windowFrameStates.Keys
                .Where(id => !activeWindowIds.Contains(id))
                .ToList();

            foreach (var id in staleIds)
            {
                _windowFrameStates.Remove(id);
            }

            if (staleIds.Count > 0)
            {
                _logger.Debug($"Cleaned up {staleIds.Count} stale window frame states");
            }
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        _cts?.Cancel();
        try
        {
            _captureTask?.Wait(TimeSpan.FromSeconds(2));
        }
        catch
        {
            // Ignore exceptions during cleanup
        }

        _cts?.Dispose();

        lock (_stateLock)
        {
            _windowFrameStates.Clear();
        }

        _logger.Info($"FrameStreamingService disposed. Stats: {Stats}");
    }
}

/// <summary>
/// Per-window frame capture state tracking.
/// </summary>
internal sealed record WindowFrameState
{
    public required ulong WindowId { get; init; }
    public required DateTime LastCaptureTime { get; init; }
    public required uint FrameCount { get; init; }
}

/// <summary>
/// Statistics for frame streaming diagnostics.
/// </summary>
public sealed class FrameStreamingStats
{
    private long _captureAttempts;
    private long _framesCaptured;
    private long _framesWritten;
    private long _notificationsSent;
    private long _captureErrors;
    private long _bufferFullCount;
    private long _framesCompressed;
    private long _bytesSavedByCompression;

    public long CaptureAttempts => Interlocked.Read(ref _captureAttempts);
    public long FramesCaptured => Interlocked.Read(ref _framesCaptured);
    public long FramesWritten => Interlocked.Read(ref _framesWritten);
    public long NotificationsSent => Interlocked.Read(ref _notificationsSent);
    public long CaptureErrors => Interlocked.Read(ref _captureErrors);
    public long BufferFullCount => Interlocked.Read(ref _bufferFullCount);
    public long FramesCompressed => Interlocked.Read(ref _framesCompressed);
    public long BytesSavedByCompression => Interlocked.Read(ref _bytesSavedByCompression);

    internal void RecordCaptureAttempt() => Interlocked.Increment(ref _captureAttempts);
    internal void RecordFrameCaptured() => Interlocked.Increment(ref _framesCaptured);
    internal void RecordFrameWritten() => Interlocked.Increment(ref _framesWritten);
    internal void RecordNotificationSent() => Interlocked.Increment(ref _notificationsSent);
    internal void RecordCaptureError() => Interlocked.Increment(ref _captureErrors);
    internal void RecordBufferFull() => Interlocked.Increment(ref _bufferFullCount);

    internal void RecordFrameCompressed(int bytesSaved)
    {
        Interlocked.Increment(ref _framesCompressed);
        Interlocked.Add(ref _bytesSavedByCompression, bytesSaved);
    }

    public override string ToString() =>
        $"Attempts={CaptureAttempts}, Captured={FramesCaptured}, Written={FramesWritten}, " +
        $"Sent={NotificationsSent}, Errors={CaptureErrors}, BufferFull={BufferFullCount}, " +
        $"Compressed={FramesCompressed}, SavedKB={BytesSavedByCompression / 1024}";
}
