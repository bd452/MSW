using System.IO.Pipes;
using System.Threading.Channels;

namespace WinRun.Agent.Services;

/// <summary>
/// Handles communication with the host via Spice port channel.
/// <para>
/// The Spice port channel is exposed to Windows guests via VirtIO serial.
/// This class supports two connection methods:
/// 1. Named pipe (for development with QEMU -chardev socket)
/// 2. VirtIO serial device (for production with proper Spice setup)
/// </para>
/// <para>
/// For VirtIO serial to work, the guest must have the virtio-serial driver
/// installed (part of virtio-win drivers). The port appears as a COM device.
/// </para>
/// </summary>
public sealed class SpiceControlPort : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly Channel<HostMessage> _inboundChannel;
    private readonly Channel<GuestMessage> _outboundChannel;
    private readonly CancellationTokenSource _cts = new();
    private Task? _readTask;
    private Task? _writeTask;
    private Stream? _stream;
    private bool _disposed;

    /// <summary>
    /// The port name for the Spice control channel.
    /// Must match WINRUN_CONTROL_PORT_NAME in the host C bridge.
    /// </summary>
    private const string CONTROL_PORT_NAME = "com.winrun.control";

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
    /// Attempts to connect to the Spice control channel.
    /// Tries multiple connection methods in order of preference.
    /// Returns true if successful, false otherwise.
    /// </summary>
    public bool TryOpen()
    {
        // Method 1: Try named pipe (for development/QEMU socket mode)
        if (TryOpenNamedPipe())
        {
            return true;
        }

        // Method 2: Try VirtIO serial device file
        // On Windows, virtio-serial ports appear as \\.\Global\<portname>
        if (TryOpenVirtioSerial())
        {
            return true;
        }

        _logger.Warn("Could not connect to Spice control channel");
        return false;
    }

    private bool TryOpenNamedPipe()
    {
        try
        {
            var pipe = new NamedPipeClientStream(
                ".",
                CONTROL_PORT_NAME,
                PipeDirection.InOut,
                PipeOptions.Asynchronous);

            // Try to connect with a short timeout
            pipe.Connect(500);
            _stream = pipe;
            _logger.Info($"Connected to control channel via named pipe: {CONTROL_PORT_NAME}");
            return true;
        }
        catch (TimeoutException)
        {
            _logger.Debug($"Named pipe {CONTROL_PORT_NAME} connection timed out");
            return false;
        }
        catch (Exception ex)
        {
            _logger.Debug($"Named pipe {CONTROL_PORT_NAME} not available: {ex.Message}");
            return false;
        }
    }

    private bool TryOpenVirtioSerial()
    {
        // VirtIO serial ports on Windows appear as:
        // \\.\Global\<portname> (when using virtioserial driver)
        var devicePath = $@"\\.\Global\{CONTROL_PORT_NAME}";

        try
        {
            // Open as a file stream with overlapped I/O for async support
            var fileStream = new FileStream(
                devicePath,
                FileMode.Open,
                FileAccess.ReadWrite,
                FileShare.None,
                bufferSize: 4096,
                useAsync: true);

            _stream = fileStream;
            _logger.Info($"Connected to control channel via VirtIO serial: {devicePath}");
            return true;
        }
        catch (Exception ex)
        {
            _logger.Debug($"VirtIO serial {devicePath} not available: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Starts the read and write loops.
    /// </summary>
    public void Start()
    {
        if (_stream == null || !_stream.CanRead)
        {
            _logger.Warn("Cannot start SpiceControlPort - not connected");
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

        while (!token.IsCancellationRequested && _stream?.CanRead == true)
        {
            try
            {
                var bytesRead = await _stream.ReadAsync(buffer, token);

                if (bytesRead == 0)
                {
                    // Stream closed
                    _logger.Warn("Control channel closed by host");
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
            var payloadLength = (int)length;
            var payload = new byte[payloadLength];
            _ = _readBuffer.Read(payload, 0, payloadLength);

            // Remove processed data from buffer
            var remainingLength = (int)(_readBuffer.Length - 5 - payloadLength);
            var remaining = new byte[remainingLength];
            if (remainingLength > 0)
            {
                _ = _readBuffer.Read(remaining, 0, remainingLength);
            }

            _readBuffer.SetLength(0);
            if (remainingLength > 0)
            {
                _readBuffer.Write(remaining, 0, remainingLength);
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

        while (!token.IsCancellationRequested && _stream?.CanWrite == true)
        {
            try
            {
                var message = await reader.ReadAsync(token);
                var bytes = SpiceMessageSerializer.Serialize(message);

                await _stream.WriteAsync(bytes, token);
                await _stream.FlushAsync(token);
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
        _stream?.Dispose();
        _readBuffer.Dispose();
        _disposed = true;
    }
}
