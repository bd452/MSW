using System.IO.Pipes;
using System.Threading.Channels;

namespace WinRun.Agent.Services;

/// <summary>
/// Handles communication with the host via Spice port channel.
/// Reads messages from the named pipe and writes to an inbound channel.
/// Reads from an outbound channel and writes to the pipe.
/// </summary>
public sealed class SpiceControlPort : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly Channel<HostMessage> _inboundChannel;
    private readonly Channel<GuestMessage> _outboundChannel;
    private readonly CancellationTokenSource _cts = new();
    private Task? _readTask;
    private Task? _writeTask;
    private NamedPipeClientStream? _pipe;
    private bool _disposed;

    /// <summary>
    /// The named pipe path for the Spice control channel.
    /// This matches the port name configured in the host.
    /// </summary>
    private const string PipeName = "com.winrun.control";

    /// <summary>
    /// Buffer for accumulating partial messages.
    /// </summary>
    private readonly MemoryStream _readBuffer = new();

    public SpiceControlPort(
        IAgentLogger logger,
        Channel<HostMessage> inboundChannel,
        Channel<GuestMessage> outboundChannel)
    {
        _logger = logger;
        _inboundChannel = inboundChannel;
        _outboundChannel = outboundChannel;
    }

    /// <summary>
    /// Attempts to connect to the Spice control pipe.
    /// Returns true if successful, false otherwise.
    /// </summary>
    public bool TryOpen()
    {
        // Try connecting to the named pipe
        // The pipe is created by the VirtIO driver or QEMU
        try
        {
            _pipe = new NamedPipeClientStream(
                ".",
                PipeName,
                PipeDirection.InOut,
                PipeOptions.Asynchronous);

            // Try to connect with a short timeout
            _pipe.Connect(1000);
            _logger.Info($"Connected to control pipe: {PipeName}");
            return true;
        }
        catch (TimeoutException)
        {
            _logger.Debug($"Pipe {PipeName} connection timed out");
            _pipe?.Dispose();
            _pipe = null;
            return false;
        }
        catch (Exception ex)
        {
            _logger.Debug($"Failed to connect to pipe {PipeName}: {ex.Message}");
            _pipe?.Dispose();
            _pipe = null;
            return false;
        }
    }

    /// <summary>
    /// Starts the read and write loops.
    /// </summary>
    public void Start()
    {
        if (_pipe == null || !_pipe.IsConnected)
        {
            _logger.Warn("Cannot start SpiceControlPort - pipe not connected");
            return;
        }

        _readTask = Task.Run(() => ReadLoopAsync(_cts.Token));
        _writeTask = Task.Run(() => WriteLoopAsync(_cts.Token));

        _logger.Info("SpiceControlPort started");
    }

    /// <summary>
    /// Stops the read and write loops.
    /// </summary>
    public async Task StopAsync()
    {
        _cts.Cancel();

        if (_readTask != null)
        {
            try
            {
                await _readTask;
            }
            catch (OperationCanceledException)
            {
                // Expected
            }
        }

        if (_writeTask != null)
        {
            try
            {
                await _writeTask;
            }
            catch (OperationCanceledException)
            {
                // Expected
            }
        }

        _logger.Info("SpiceControlPort stopped");
    }

    private async Task ReadLoopAsync(CancellationToken token)
    {
        var buffer = new byte[4096];

        while (!token.IsCancellationRequested && _pipe?.IsConnected == true)
        {
            try
            {
                var bytesRead = await _pipe.ReadAsync(buffer, token);

                if (bytesRead == 0)
                {
                    // Pipe closed
                    _logger.Warn("Control pipe closed by host");
                    break;
                }

                // Append to read buffer
                _readBuffer.Write(buffer, 0, bytesRead);

                // Try to parse complete messages
                await ProcessReadBufferAsync(token);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.Error($"Read error: {ex.Message}");
                await Task.Delay(100, token);
            }
        }
    }

    private async Task ProcessReadBufferAsync(CancellationToken token)
    {
        // Message format: [Type:1][Length:4][Payload:N]
        while (_readBuffer.Length >= 5)
        {
            _readBuffer.Position = 0;
            var headerBytes = new byte[5];
            _ = _readBuffer.Read(headerBytes, 0, 5);

            var length = BitConverter.ToUInt32(headerBytes, 1);

            // Check if we have the complete message
            if (_readBuffer.Length - 5 < length)
            {
                // Not enough data yet, wait for more
                _readBuffer.Position = _readBuffer.Length;
                return;
            }

            // Read the payload
            var payload = new byte[length];
            _ = _readBuffer.Read(payload, 0, (int)length);

            // Remove processed data from buffer
            var remaining = new byte[_readBuffer.Length - 5 - length];
            if (remaining.Length > 0)
            {
                _ = _readBuffer.Read(remaining, 0, remaining.Length);
            }

            _readBuffer.SetLength(0);
            if (remaining.Length > 0)
            {
                _readBuffer.Write(remaining, 0, remaining.Length);
            }

            // Parse and queue the message
            try
            {
                var fullMessage = new byte[5 + length];
                Array.Copy(headerBytes, 0, fullMessage, 0, 5);
                Array.Copy(payload, 0, fullMessage, 5, (int)length);

                var message = SpiceMessageSerializer.Deserialize(fullMessage);
                if (message != null)
                {
                    await _inboundChannel.Writer.WriteAsync(message, token);
                    _logger.Debug($"Received message: {message.GetType().Name}");
                }
            }
            catch (Exception ex)
            {
                _logger.Error($"Failed to parse message: {ex.Message}");
            }
        }
    }

    private async Task WriteLoopAsync(CancellationToken token)
    {
        var reader = _outboundChannel.Reader;

        while (!token.IsCancellationRequested && _pipe?.IsConnected == true)
        {
            try
            {
                var message = await reader.ReadAsync(token);
                var bytes = SpiceMessageSerializer.Serialize(message);

                await _pipe.WriteAsync(bytes, token);
                await _pipe.FlushAsync(token);
                _logger.Debug($"Sent message: {message.GetType().Name} ({bytes.Length} bytes)");
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.Error($"Write error: {ex.Message}");
            }
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _cts.Cancel();
        _cts.Dispose();
        _pipe?.Dispose();
        _readBuffer.Dispose();
        _disposed = true;
    }
}
