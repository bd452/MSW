using System.IO.Ports;
using System.Threading.Channels;

namespace WinRun.Agent.Services;

/// <summary>
/// Handles communication with the host via Spice port channel.
/// Reads messages from the VirtIO serial port and writes to an inbound channel.
/// Reads from an outbound channel and writes to the serial port.
/// </summary>
public sealed class SpiceControlPort : IDisposable
{
    private readonly IAgentLogger _logger;
    private readonly Channel<HostMessage> _inboundChannel;
    private readonly Channel<GuestMessage> _outboundChannel;
    private readonly CancellationTokenSource _cts = new();
    private Task? _readTask;
    private Task? _writeTask;
    private SerialPort? _port;
    private bool _disposed;

    /// <summary>
    /// The port name pattern for the Spice control channel.
    /// On Windows, VirtIO serial ports appear as COM ports.
    /// </summary>
    private const string ControlPortName = "com.winrun.control";

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
    /// Attempts to find and open the Spice control port.
    /// Returns true if successful, false otherwise.
    /// </summary>
    public bool TryOpen()
    {
        // On Windows, VirtIO serial ports appear as COM ports
        // We need to enumerate available ports and find the one that matches
        // For now, try common patterns

        // Method 1: Check for WinRun-specific port symlink
        // The VirtIO driver can create named symlinks for ports
        var symLinkPath = @"\\.\Global\com.winrun.control";
        if (TryOpenPort(symLinkPath))
        {
            return true;
        }

        // Method 2: Try standard COM ports
        // This is a fallback - in production, we'd use device enumeration
        foreach (var portName in SerialPort.GetPortNames())
        {
            _logger.Debug($"Checking port: {portName}");
            // Skip common real COM ports
            if (portName is "COM1" or "COM2")
            {
                continue;
            }

            if (TryOpenPort(portName))
            {
                _logger.Info($"Opened control port on {portName}");
                return true;
            }
        }

        // Method 3: Try virtio-serial pipe path
        // Some VirtIO configurations expose ports as named pipes
        var pipePath = @"\\.\pipe\com.winrun.control";
        if (TryOpenPort(pipePath))
        {
            _logger.Info($"Opened control port via pipe: {pipePath}");
            return true;
        }

        _logger.Warn("Could not find Spice control port");
        return false;
    }

    private bool TryOpenPort(string portName)
    {
        try
        {
            // For pipe paths, we can't use SerialPort
            if (portName.StartsWith(@"\\.\pipe\"))
            {
                // Named pipe handling would go here
                // For now, skip - we'll handle this case later
                return false;
            }

            var port = new SerialPort(portName)
            {
                BaudRate = 115200,
                DataBits = 8,
                Parity = Parity.None,
                StopBits = StopBits.One,
                ReadTimeout = 100,
                WriteTimeout = 1000
            };

            port.Open();
            _port = port;
            return true;
        }
        catch (Exception ex)
        {
            _logger.Debug($"Failed to open {portName}: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Starts the read and write loops.
    /// </summary>
    public void Start()
    {
        if (_port == null || !_port.IsOpen)
        {
            _logger.Warn("Cannot start SpiceControlPort - port not open");
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
            try { await _readTask; } catch (OperationCanceledException) { }
        }

        if (_writeTask != null)
        {
            try { await _writeTask; } catch (OperationCanceledException) { }
        }

        _logger.Info("SpiceControlPort stopped");
    }

    private async Task ReadLoopAsync(CancellationToken token)
    {
        var buffer = new byte[4096];

        while (!token.IsCancellationRequested && _port?.IsOpen == true)
        {
            try
            {
                // Read available data
                int bytesRead;
                try
                {
                    bytesRead = _port.Read(buffer, 0, buffer.Length);
                }
                catch (TimeoutException)
                {
                    // No data available, continue
                    await Task.Delay(10, token);
                    continue;
                }

                if (bytesRead > 0)
                {
                    // Append to read buffer
                    _readBuffer.Write(buffer, 0, bytesRead);

                    // Try to parse complete messages
                    await ProcessReadBufferAsync(token);
                }
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

            var messageType = headerBytes[0];
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

        while (!token.IsCancellationRequested && _port?.IsOpen == true)
        {
            try
            {
                var message = await reader.ReadAsync(token);
                var bytes = SpiceMessageSerializer.Serialize(message);

                _port.Write(bytes, 0, bytes.Length);
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
        _port?.Dispose();
        _readBuffer.Dispose();
        _disposed = true;
    }
}
