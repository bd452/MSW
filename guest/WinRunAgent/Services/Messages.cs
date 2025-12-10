using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WinRun.Agent.Services;

/// <summary>
/// Protocol version for host↔guest communication.
/// Increment when making breaking changes to message formats.
/// </summary>
public static class ProtocolVersion
{
    public const ushort Major = 1;
    public const ushort Minor = 0;

    public static uint Combined => ((uint)Major << 16) | Minor;
}

/// <summary>
/// Message type identifiers for Spice channel serialization.
/// Values 0x00-0x7F are reserved for host→guest messages.
/// Values 0x80-0xFF are reserved for guest→host messages.
/// </summary>
public enum SpiceMessageType : byte
{
    // Host → Guest (0x00-0x7F)
    LaunchProgram = 0x01,
    RequestIcon = 0x02,
    ClipboardData = 0x03,
    MouseInput = 0x04,
    KeyboardInput = 0x05,
    DragDropEvent = 0x06,
    Shutdown = 0x0F,

    // Guest → Host (0x80-0xFF)
    WindowMetadata = 0x80,
    FrameData = 0x81,
    CapabilityFlags = 0x82,
    DpiInfo = 0x83,
    IconData = 0x84,
    ShortcutDetected = 0x85,
    ClipboardChanged = 0x86,
    Heartbeat = 0x87,
    Error = 0xFE,
    Ack = 0xFF
}

/// <summary>
/// Capability flags reported by the guest agent.
/// </summary>
[Flags]
public enum GuestCapabilities : uint
{
    None = 0,
    WindowTracking = 1 << 0,
    DesktopDuplication = 1 << 1,
    ClipboardSync = 1 << 2,
    DragDrop = 1 << 3,
    IconExtraction = 1 << 4,
    ShortcutDetection = 1 << 5,
    HighDpiSupport = 1 << 6,
    MultiMonitor = 1 << 7
}

// ============================================================================
// Host → Guest Messages
// ============================================================================

/// <summary>
/// Base record for messages from host to guest.
/// </summary>
public abstract record HostMessage
{
    /// <summary>
    /// Unique message ID for acknowledgement tracking.
    /// </summary>
    public uint MessageId { get; init; }
}

/// <summary>
/// Request to launch a program on the guest.
/// </summary>
public sealed record LaunchProgramMessage : HostMessage
{
    public required string Path { get; init; }
    public string[] Arguments { get; init; } = [];
    public string? WorkingDirectory { get; init; }
    public Dictionary<string, string>? Environment { get; init; }
}

/// <summary>
/// Request to extract and send an icon for an executable.
/// </summary>
public sealed record RequestIconMessage : HostMessage
{
    public required string ExecutablePath { get; init; }
    public int PreferredSize { get; init; } = 256;
}

/// <summary>
/// Clipboard data from host to guest.
/// </summary>
public sealed record HostClipboardMessage : HostMessage
{
    public required ClipboardFormat Format { get; init; }
    public required byte[] Data { get; init; }
    public ulong SequenceNumber { get; init; }
}

/// <summary>
/// Mouse input event from host.
/// </summary>
public sealed record MouseInputMessage : HostMessage
{
    public ulong WindowId { get; init; }
    public MouseEventType EventType { get; init; }
    public MouseButton? Button { get; init; }
    public double X { get; init; }
    public double Y { get; init; }
    public double ScrollDeltaX { get; init; }
    public double ScrollDeltaY { get; init; }
    public KeyModifiers Modifiers { get; init; }
}

/// <summary>
/// Keyboard input event from host.
/// </summary>
public sealed record KeyboardInputMessage : HostMessage
{
    public ulong WindowId { get; init; }
    public KeyEventType EventType { get; init; }
    public uint KeyCode { get; init; }
    public uint ScanCode { get; init; }
    public bool IsExtendedKey { get; init; }
    public KeyModifiers Modifiers { get; init; }
    public string? Character { get; init; }
}

/// <summary>
/// Drag and drop event from host.
/// </summary>
public sealed record DragDropMessage : HostMessage
{
    public ulong WindowId { get; init; }
    public DragDropEventType EventType { get; init; }
    public double X { get; init; }
    public double Y { get; init; }
    public DraggedFileInfo[] Files { get; init; } = [];
    public DragOperation[] AllowedOperations { get; init; } = [DragOperation.Copy];
    public DragOperation? SelectedOperation { get; init; }
}

/// <summary>
/// Graceful shutdown request.
/// </summary>
public sealed record ShutdownMessage : HostMessage
{
    public int TimeoutMs { get; init; } = 5000;
}

// ============================================================================
// Guest → Host Messages
// ============================================================================

/// <summary>
/// Base record for messages from guest to host.
/// </summary>
public abstract record GuestMessage
{
    /// <summary>
    /// Timestamp when the message was created (Unix milliseconds).
    /// </summary>
    public long Timestamp { get; init; } = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

/// <summary>
/// Window metadata update sent when windows change.
/// </summary>
public sealed record WindowMetadataMessage : GuestMessage
{
    public required ulong WindowId { get; init; }
    public required string Title { get; init; }
    public required RectInfo Bounds { get; init; }
    public required WindowEventType EventType { get; init; }
    public uint ProcessId { get; init; }
    public string? ClassName { get; init; }
    public bool IsMinimized { get; init; }
    public bool IsResizable { get; init; } = true;
    public double ScaleFactor { get; init; } = 1.0;
}

/// <summary>
/// Frame data for a window (header only - actual pixel data sent separately).
/// </summary>
public sealed record FrameDataMessage : GuestMessage
{
    public required ulong WindowId { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }
    public required int Stride { get; init; }
    public required PixelFormatType Format { get; init; }
    public required uint DataLength { get; init; }
    public uint FrameNumber { get; init; }
    public bool IsKeyFrame { get; init; } = true;
}

/// <summary>
/// Guest capability announcement.
/// </summary>
public sealed record CapabilityFlagsMessage : GuestMessage
{
    public required GuestCapabilities Capabilities { get; init; }
    public required uint ProtocolVersion { get; init; }
    public string AgentVersion { get; init; } = "1.0.0";
    public string OsVersion { get; init; } = Environment.OSVersion.VersionString;
}

/// <summary>
/// DPI and display information.
/// </summary>
public sealed record DpiInfoMessage : GuestMessage
{
    public required int PrimaryDpi { get; init; }
    public required double ScaleFactor { get; init; }
    public required MonitorInfo[] Monitors { get; init; }
}

/// <summary>
/// Icon data extracted from an executable.
/// </summary>
public sealed record IconDataMessage : GuestMessage
{
    public required string ExecutablePath { get; init; }
    public required int Width { get; init; }
    public required int Height { get; init; }
    public required byte[] PngData { get; init; }
}

/// <summary>
/// Shortcut detection notification.
/// </summary>
public sealed record ShortcutDetectedMessage : GuestMessage
{
    public required string ShortcutPath { get; init; }
    public required string TargetPath { get; init; }
    public string? DisplayName { get; init; }
    public string? IconPath { get; init; }
}

/// <summary>
/// Clipboard change notification from guest.
/// </summary>
public sealed record GuestClipboardMessage : GuestMessage
{
    public required ClipboardFormat Format { get; init; }
    public required byte[] Data { get; init; }
    public ulong SequenceNumber { get; init; }
}

/// <summary>
/// Heartbeat to indicate agent is alive.
/// </summary>
public sealed record HeartbeatMessage : GuestMessage
{
    public int TrackedWindowCount { get; init; }
    public long UptimeMs { get; init; }
    public float CpuUsagePercent { get; init; }
    public long MemoryUsageBytes { get; init; }
}

/// <summary>
/// Error notification from guest.
/// </summary>
public sealed record ErrorMessage : GuestMessage
{
    public required string Code { get; init; }
    public required string Message { get; init; }
    public uint? RelatedMessageId { get; init; }
}

/// <summary>
/// Acknowledgement of a host message.
/// </summary>
public sealed record AckMessage : GuestMessage
{
    public required uint MessageId { get; init; }
    public bool Success { get; init; } = true;
    public string? ErrorMessage { get; init; }
}

// ============================================================================
// Supporting Types
// ============================================================================

/// <summary>
/// Rectangle bounds information.
/// </summary>
public readonly record struct RectInfo(int X, int Y, int Width, int Height);

/// <summary>
/// Monitor/display information.
/// </summary>
public sealed record MonitorInfo
{
    public required string DeviceName { get; init; }
    public required RectInfo Bounds { get; init; }
    public required RectInfo WorkArea { get; init; }
    public required int Dpi { get; init; }
    public required double ScaleFactor { get; init; }
    public bool IsPrimary { get; init; }
}

/// <summary>
/// File information for drag and drop.
/// </summary>
public sealed record DraggedFileInfo
{
    public required string HostPath { get; init; }
    public string? GuestPath { get; init; }
    public ulong FileSize { get; init; }
    public bool IsDirectory { get; init; }
}

/// <summary>
/// Pixel format for frame data.
/// </summary>
public enum PixelFormatType : byte
{
    Bgra32 = 0,
    Rgba32 = 1
}

/// <summary>
/// Mouse button identifiers (matching Windows VK codes).
/// </summary>
public enum MouseButton : byte
{
    Left = 1,
    Right = 2,
    Middle = 4,
    Extra1 = 5,
    Extra2 = 6
}

/// <summary>
/// Mouse event types.
/// </summary>
public enum MouseEventType : byte
{
    Move = 0,
    Press = 1,
    Release = 2,
    Scroll = 3
}

/// <summary>
/// Keyboard event types.
/// </summary>
public enum KeyEventType : byte
{
    KeyDown = 0,
    KeyUp = 1
}

/// <summary>
/// Modifier key flags.
/// </summary>
[Flags]
public enum KeyModifiers : byte
{
    None = 0,
    Shift = 1 << 0,
    Control = 1 << 1,
    Alt = 1 << 2,
    Command = 1 << 3,
    CapsLock = 1 << 4,
    NumLock = 1 << 5
}

/// <summary>
/// Drag operation types.
/// </summary>
public enum DragOperation : byte
{
    None = 0,
    Copy = 1,
    Move = 2,
    Link = 3
}

/// <summary>
/// Drag and drop event types.
/// </summary>
public enum DragDropEventType : byte
{
    Enter = 0,
    Move = 1,
    Leave = 2,
    Drop = 3
}

/// <summary>
/// Clipboard data formats (matching macOS UTI identifiers).
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ClipboardFormat
{
    PlainText,
    Rtf,
    Html,
    Png,
    Tiff,
    FileUrl
}

// ============================================================================
// Serialization
// ============================================================================

/// <summary>
/// Serializes and deserializes Spice channel messages using a binary format.
/// Message format: [Type:1][Length:4][Payload:N]
/// </summary>
public static class SpiceMessageSerializer
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    /// <summary>
    /// Serializes a guest message to bytes for transmission over Spice channel.
    /// </summary>
    public static byte[] Serialize(GuestMessage message)
    {
        var type = message switch
        {
            WindowMetadataMessage => SpiceMessageType.WindowMetadata,
            FrameDataMessage => SpiceMessageType.FrameData,
            CapabilityFlagsMessage => SpiceMessageType.CapabilityFlags,
            DpiInfoMessage => SpiceMessageType.DpiInfo,
            IconDataMessage => SpiceMessageType.IconData,
            ShortcutDetectedMessage => SpiceMessageType.ShortcutDetected,
            GuestClipboardMessage => SpiceMessageType.ClipboardChanged,
            HeartbeatMessage => SpiceMessageType.Heartbeat,
            ErrorMessage => SpiceMessageType.Error,
            AckMessage => SpiceMessageType.Ack,
            _ => throw new ArgumentException($"Unknown message type: {message.GetType()}")
        };

        var payload = JsonSerializer.SerializeToUtf8Bytes(message, message.GetType(), JsonOptions);
        return CreateEnvelope(type, payload);
    }

    /// <summary>
    /// Serializes frame data with a separate binary payload.
    /// Returns header envelope + raw frame data.
    /// </summary>
    public static (byte[] Header, byte[] Data) SerializeFrame(FrameDataMessage header, byte[] frameData)
    {
        var headerBytes = Serialize(header);
        return (headerBytes, frameData);
    }

    /// <summary>
    /// Deserializes a host message from bytes received over Spice channel.
    /// </summary>
    public static HostMessage? Deserialize(ReadOnlySpan<byte> data)
    {
        if (data.Length < 5)
        {
            return null;
        }

        var type = (SpiceMessageType)data[0];
        var length = BinaryPrimitives.ReadUInt32LittleEndian(data[1..]);

        if (data.Length < 5 + length)
        {
            return null;
        }

        var payload = data.Slice(5, (int)length);

        return type switch
        {
            SpiceMessageType.LaunchProgram => JsonSerializer.Deserialize<LaunchProgramMessage>(payload, JsonOptions),
            SpiceMessageType.RequestIcon => JsonSerializer.Deserialize<RequestIconMessage>(payload, JsonOptions),
            SpiceMessageType.ClipboardData => JsonSerializer.Deserialize<HostClipboardMessage>(payload, JsonOptions),
            SpiceMessageType.MouseInput => JsonSerializer.Deserialize<MouseInputMessage>(payload, JsonOptions),
            SpiceMessageType.KeyboardInput => JsonSerializer.Deserialize<KeyboardInputMessage>(payload, JsonOptions),
            SpiceMessageType.DragDropEvent => JsonSerializer.Deserialize<DragDropMessage>(payload, JsonOptions),
            SpiceMessageType.Shutdown => JsonSerializer.Deserialize<ShutdownMessage>(payload, JsonOptions),
            SpiceMessageType.WindowMetadata => throw new NotImplementedException(),
            SpiceMessageType.FrameData => throw new NotImplementedException(),
            SpiceMessageType.CapabilityFlags => throw new NotImplementedException(),
            SpiceMessageType.DpiInfo => throw new NotImplementedException(),
            SpiceMessageType.IconData => throw new NotImplementedException(),
            SpiceMessageType.ShortcutDetected => throw new NotImplementedException(),
            SpiceMessageType.ClipboardChanged => throw new NotImplementedException(),
            SpiceMessageType.Heartbeat => throw new NotImplementedException(),
            SpiceMessageType.Error => throw new NotImplementedException(),
            SpiceMessageType.Ack => throw new NotImplementedException(),
            _ => null
        };
    }

    /// <summary>
    /// Attempts to read a complete message from a stream buffer.
    /// Returns the number of bytes consumed, or 0 if incomplete.
    /// </summary>
    public static int TryReadMessage(ReadOnlySpan<byte> buffer, out HostMessage? message)
    {
        message = null;

        if (buffer.Length < 5)
        {
            return 0;
        }

        var length = BinaryPrimitives.ReadUInt32LittleEndian(buffer[1..]);
        var totalLength = 5 + (int)length;

        if (buffer.Length < totalLength)
        {
            return 0;
        }

        message = Deserialize(buffer[..totalLength]);
        return totalLength;
    }

    /// <summary>
    /// Creates a message envelope with type and length prefix.
    /// </summary>
    private static byte[] CreateEnvelope(SpiceMessageType type, byte[] payload)
    {
        var envelope = new byte[5 + payload.Length];
        envelope[0] = (byte)type;
        BinaryPrimitives.WriteUInt32LittleEndian(envelope.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(envelope, 5);
        return envelope;
    }

    /// <summary>
    /// Creates a capability flags message for initial handshake.
    /// </summary>
    public static CapabilityFlagsMessage CreateCapabilityMessage(GuestCapabilities capabilities) => new()
    {
        Capabilities = capabilities,
        ProtocolVersion = ProtocolVersion.Combined
    };

    /// <summary>
    /// Creates a DPI info message from gathered display information.
    /// </summary>
    public static DpiInfoMessage CreateDpiInfoMessage(int primaryDpi, double scaleFactor, IReadOnlyList<MonitorInfo> monitors) => new()
    {
        PrimaryDpi = primaryDpi,
        ScaleFactor = scaleFactor,
        Monitors = [.. monitors]
    };

    /// <summary>
    /// Creates a window metadata message from WindowTracker event args.
    /// </summary>
    public static WindowMetadataMessage CreateWindowMetadata(WindowEventArgs args, bool isResizable = true, double scaleFactor = 1.0) => new()
    {
        WindowId = args.WindowId,
        Title = args.Title,
        Bounds = new RectInfo(args.Bounds.X, args.Bounds.Y, args.Bounds.Width, args.Bounds.Height),
        EventType = args.EventType,
        IsResizable = isResizable,
        ScaleFactor = scaleFactor
    };

    /// <summary>
    /// Creates a frame data message header for a captured frame.
    /// </summary>
    public static FrameDataMessage CreateFrameHeader(
        ulong windowId,
        CapturedFrame frame,
        uint frameNumber,
        bool isKeyFrame = true) => new()
        {
            WindowId = windowId,
            Width = frame.Width,
            Height = frame.Height,
            Stride = frame.Stride,
            Format = frame.Format == PixelFormat.BGRA32 ? PixelFormatType.Bgra32 : PixelFormatType.Rgba32,
            DataLength = (uint)frame.Data.Length,
            FrameNumber = frameNumber,
            IsKeyFrame = isKeyFrame
        };
}
