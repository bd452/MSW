using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

public sealed class MessagesTests
{
    [Fact]
    public void ProtocolVersionCombinedIsCorrect()
    {
        var expected = ((uint)ProtocolVersion.Major << 16) | ProtocolVersion.Minor;

        Assert.Equal(expected, ProtocolVersion.Combined);
    }

    [Fact]
    public void GuestCapabilitiesFlagsAreDistinct()
    {
        var capabilities = Enum.GetValues<GuestCapabilities>();

        // Each flag should be a power of 2 (except None)
        foreach (var cap in capabilities)
        {
            if (cap == GuestCapabilities.None)
            {
                Assert.Equal(0u, (uint)cap);
            }
            else
            {
                // Count bits set - should be exactly 1
                var value = (uint)cap;
                var bitCount = 0;
                while (value != 0)
                {
                    bitCount += (int)(value & 1);
                    value >>= 1;
                }
                Assert.Equal(1, bitCount);
            }
        }
    }

    [Fact]
    public void CreateCapabilityMessageSetsAllFields()
    {
        var caps = GuestCapabilities.WindowTracking | GuestCapabilities.ClipboardSync;

        var message = SpiceMessageSerializer.CreateCapabilityMessage(caps);

        Assert.Equal(caps, message.Capabilities);
        Assert.Equal(ProtocolVersion.Combined, message.ProtocolVersion);
        Assert.NotEmpty(message.AgentVersion);
        Assert.NotEmpty(message.OsVersion);
    }

    [Fact]
    public void CreateDpiInfoMessageSetsAllFields()
    {
        var monitors = new List<MonitorInfo>
        {
            new()
            {
                DeviceName = "PRIMARY",
                Bounds = new RectInfo(0, 0, 1920, 1080),
                WorkArea = new RectInfo(0, 40, 1920, 1040),
                Dpi = 96,
                ScaleFactor = 1.0,
                IsPrimary = true
            },
            new()
            {
                DeviceName = "SECONDARY",
                Bounds = new RectInfo(1920, 0, 2560, 1440),
                WorkArea = new RectInfo(1920, 0, 2560, 1400),
                Dpi = 144,
                ScaleFactor = 1.5,
                IsPrimary = false
            }
        };

        var message = SpiceMessageSerializer.CreateDpiInfoMessage(96, 1.0, monitors);

        Assert.Equal(96, message.PrimaryDpi);
        Assert.Equal(1.0, message.ScaleFactor);
        Assert.Equal(2, message.Monitors.Length);
        Assert.True(message.Monitors[0].IsPrimary);
        Assert.False(message.Monitors[1].IsPrimary);
    }

    [Fact]
    public void CreateWindowMetadataFromEventArgs()
    {
        var args = new WindowEventArgs(
            WindowId: 12345,
            Title: "Test Window",
            Bounds: new Rect(100, 200, 800, 600),
            EventType: WindowEventType.Created);

        var message = SpiceMessageSerializer.CreateWindowMetadata(args, isResizable: true, scaleFactor: 1.25);

        Assert.Equal(12345UL, message.WindowId);
        Assert.Equal("Test Window", message.Title);
        Assert.Equal(WindowEventType.Created, message.EventType);
        Assert.True(message.IsResizable);
        Assert.Equal(1.25, message.ScaleFactor);
        Assert.Equal(100, message.Bounds.X);
        Assert.Equal(200, message.Bounds.Y);
        Assert.Equal(800, message.Bounds.Width);
        Assert.Equal(600, message.Bounds.Height);
    }

    [Fact]
    public void SerializeCapabilityFlagsMessage()
    {
        var message = new CapabilityFlagsMessage
        {
            Capabilities = GuestCapabilities.WindowTracking | GuestCapabilities.DesktopDuplication,
            ProtocolVersion = ProtocolVersion.Combined
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        // First byte is message type
        Assert.Equal((byte)SpiceMessageType.CapabilityFlags, bytes[0]);
        // Next 4 bytes are length (little-endian)
        Assert.True(bytes.Length >= 5);
    }

    [Fact]
    public void SerializeDpiInfoMessage()
    {
        var message = new DpiInfoMessage
        {
            PrimaryDpi = 144,
            ScaleFactor = 1.5,
            Monitors =
            [
                new MonitorInfo
                {
                    DeviceName = "TEST",
                    Bounds = new RectInfo(0, 0, 1920, 1080),
                    WorkArea = new RectInfo(0, 0, 1920, 1040),
                    Dpi = 144,
                    ScaleFactor = 1.5,
                    IsPrimary = true
                }
            ]
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.DpiInfo, bytes[0]);
        Assert.True(bytes.Length >= 5);
    }

    [Fact]
    public void SerializeHeartbeatMessage()
    {
        var message = new HeartbeatMessage
        {
            TrackedWindowCount = 5,
            UptimeMs = 60000,
            CpuUsagePercent = 12.5f,
            MemoryUsageBytes = 1024 * 1024 * 100
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.Heartbeat, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void DeserializeLaunchProgramMessage()
    {
        var launch = new LaunchProgramMessage
        {
            MessageId = 42,
            Path = @"C:\Program Files\App.exe",
            Arguments = ["--arg1", "--arg2"],
            WorkingDirectory = @"C:\Users\Test"
        };

        var bytes = SerializeHostMessage(SpiceMessageType.LaunchProgram, launch);
        var result = SpiceMessageSerializer.Deserialize(bytes);

        Assert.NotNull(result);
        Assert.IsType<LaunchProgramMessage>(result);
        var msg = (LaunchProgramMessage)result;
        Assert.Equal(42u, msg.MessageId);
        Assert.Equal(@"C:\Program Files\App.exe", msg.Path);
        Assert.Equal(2, msg.Arguments.Length);
    }

    [Fact]
    public void DeserializeShutdownMessage()
    {
        var shutdown = new ShutdownMessage
        {
            MessageId = 100,
            TimeoutMs = 10000
        };

        var bytes = SerializeHostMessage(SpiceMessageType.Shutdown, shutdown);
        var result = SpiceMessageSerializer.Deserialize(bytes);

        Assert.NotNull(result);
        Assert.IsType<ShutdownMessage>(result);
        var msg = (ShutdownMessage)result;
        Assert.Equal(100u, msg.MessageId);
        Assert.Equal(10000, msg.TimeoutMs);
    }

    [Fact]
    public void TryReadMessageReturnsZeroForIncompleteData()
    {
        var data = new byte[] { 0x01, 0x00, 0x00 }; // Too short

        var consumed = SpiceMessageSerializer.TryReadMessage(data, out var message);

        Assert.Equal(0, consumed);
        Assert.Null(message);
    }

    [Fact]
    public void TryReadMessageReturnsZeroForInsufficientPayload()
    {
        // Header says payload is 100 bytes, but only provide 5
        var data = new byte[] { 0x01, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

        var consumed = SpiceMessageSerializer.TryReadMessage(data, out var message);

        Assert.Equal(0, consumed);
        Assert.Null(message);
    }

    [Fact]
    public void RectInfoValueEquality()
    {
        var r1 = new RectInfo(10, 20, 100, 200);
        var r2 = new RectInfo(10, 20, 100, 200);
        var r3 = new RectInfo(10, 20, 100, 201);

        Assert.Equal(r1, r2);
        Assert.NotEqual(r1, r3);
    }

    [Fact]
    public void MonitorInfoStoresAllProperties()
    {
        var monitor = new MonitorInfo
        {
            DeviceName = @"\\.\DISPLAY1",
            Bounds = new RectInfo(0, 0, 2560, 1440),
            WorkArea = new RectInfo(0, 0, 2560, 1400),
            Dpi = 144,
            ScaleFactor = 1.5,
            IsPrimary = true
        };

        Assert.Equal(@"\\.\DISPLAY1", monitor.DeviceName);
        Assert.Equal(144, monitor.Dpi);
        Assert.Equal(1.5, monitor.ScaleFactor);
        Assert.True(monitor.IsPrimary);
    }

    [Fact]
    public void AllSpiceMessageTypesHaveDistinctValues()
    {
        var values = Enum.GetValues<SpiceMessageType>().Select(v => (byte)v).ToList();
        var distinctValues = values.Distinct().ToList();

        Assert.Equal(values.Count, distinctValues.Count);
    }

    [Fact]
    public void HostToGuestMessageTypesAreInLowRange()
    {
        // Host→Guest messages should be 0x00-0x7F
        Assert.True((byte)SpiceMessageType.LaunchProgram <= 0x7F);
        Assert.True((byte)SpiceMessageType.RequestIcon <= 0x7F);
        Assert.True((byte)SpiceMessageType.ClipboardData <= 0x7F);
        Assert.True((byte)SpiceMessageType.MouseInput <= 0x7F);
        Assert.True((byte)SpiceMessageType.KeyboardInput <= 0x7F);
        Assert.True((byte)SpiceMessageType.DragDropEvent <= 0x7F);
        Assert.True((byte)SpiceMessageType.Shutdown <= 0x7F);
    }

    [Fact]
    public void GuestToHostMessageTypesAreInHighRange()
    {
        // Guest→Host messages should be 0x80-0xFF
        Assert.True((byte)SpiceMessageType.WindowMetadata >= 0x80);
        Assert.True((byte)SpiceMessageType.FrameData >= 0x80);
        Assert.True((byte)SpiceMessageType.CapabilityFlags >= 0x80);
        Assert.True((byte)SpiceMessageType.DpiInfo >= 0x80);
        Assert.True((byte)SpiceMessageType.IconData >= 0x80);
        Assert.True((byte)SpiceMessageType.ShortcutDetected >= 0x80);
        Assert.True((byte)SpiceMessageType.ClipboardChanged >= 0x80);
        Assert.True((byte)SpiceMessageType.Heartbeat >= 0x80);
        Assert.True((byte)SpiceMessageType.Error >= 0x80);
        Assert.True((byte)SpiceMessageType.Ack >= 0x80);
    }

    [Fact]
    public void GuestMessageTimestampIsSet()
    {
        var before = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        var message = new HeartbeatMessage();

        var after = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        Assert.InRange(message.Timestamp, before, after);
    }

    [Fact]
    public void CreateFrameHeaderSetsCorrectFormat()
    {
        var frame = new CapturedFrame(
            Width: 1920,
            Height: 1080,
            Stride: 7680,
            Format: PixelFormat.BGRA32,
            Data: new byte[1920 * 1080 * 4],
            Timestamp: 0);

        var header = SpiceMessageSerializer.CreateFrameHeader(123, frame, frameNumber: 42, isKeyFrame: true);

        Assert.Equal(123UL, header.WindowId);
        Assert.Equal(1920, header.Width);
        Assert.Equal(1080, header.Height);
        Assert.Equal(7680, header.Stride);
        Assert.Equal(PixelFormatType.Bgra32, header.Format);
        Assert.Equal(42u, header.FrameNumber);
        Assert.True(header.IsKeyFrame);
    }

    private static byte[] SerializeHostMessage<T>(SpiceMessageType type, T message) where T : HostMessage
    {
        var options = new System.Text.Json.JsonSerializerOptions
        {
            PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase
        };
        var payload = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(message, options);
        var result = new byte[5 + payload.Length];
        result[0] = (byte)type;
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(result, 5);
        return result;
    }
}

