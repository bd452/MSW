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
        var msg = Assert.IsType<LaunchProgramMessage>(result);
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
        var msg = Assert.IsType<ShutdownMessage>(result);
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
            Format: PixelFormatType.Bgra32,
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

    [Fact]
    public void CreateIconMessage_FromExtractionResult_SetsAllFields()
    {
        var pngData = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        var result = IconExtractionResult.Success(pngData, 256, 256);

        var message = SpiceMessageSerializer.CreateIconMessage(
            @"C:\App\app.exe",
            result,
            iconIndex: 0);

        Assert.Equal(@"C:\App\app.exe", message.ExecutablePath);
        Assert.Equal(256, message.Width);
        Assert.Equal(256, message.Height);
        Assert.Equal(pngData, message.PngData);
        Assert.NotEmpty(message.IconHash!);
        Assert.Equal(0, message.IconIndex);
    }

    [Fact]
    public void CreateIconMessage_FromRawData_SetsAllFields()
    {
        var pngData = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

        var message = SpiceMessageSerializer.CreateIconMessage(
            @"C:\App\app.exe",
            pngData,
            width: 128,
            height: 128,
            iconIndex: 1,
            wasScaled: true);

        Assert.Equal(@"C:\App\app.exe", message.ExecutablePath);
        Assert.Equal(128, message.Width);
        Assert.Equal(128, message.Height);
        Assert.Equal(pngData, message.PngData);
        Assert.NotEmpty(message.IconHash!);
        Assert.Equal(1, message.IconIndex);
        Assert.True(message.WasScaled);
    }

    [Fact]
    public void CreateIconMessage_SameData_SameHash()
    {
        var pngData = new byte[] { 0x89, 0x50, 0x4E, 0x47 };

        var message1 = SpiceMessageSerializer.CreateIconMessage(@"C:\App1\app.exe", pngData, 64, 64);
        var message2 = SpiceMessageSerializer.CreateIconMessage(@"C:\App2\other.exe", pngData, 64, 64);

        Assert.Equal(message1.IconHash, message2.IconHash);
    }

    [Fact]
    public void CreateIconMessage_DifferentData_DifferentHash()
    {
        var data1 = new byte[] { 0x89, 0x50, 0x4E, 0x47 };
        var data2 = new byte[] { 0x89, 0x50, 0x4E, 0x48 };

        var message1 = SpiceMessageSerializer.CreateIconMessage(@"C:\App\app.exe", data1, 64, 64);
        var message2 = SpiceMessageSerializer.CreateIconMessage(@"C:\App\app.exe", data2, 64, 64);

        Assert.NotEqual(message1.IconHash, message2.IconHash);
    }

    [Fact]
    public void CreateShortcutMessage_SetsAllFields()
    {
        var info = new ShortcutInfo
        {
            ShortcutPath = @"C:\Users\Test\Desktop\App.lnk",
            TargetPath = @"C:\Program Files\App\app.exe",
            DisplayName = "My Application",
            IconPath = @"C:\Program Files\App\app.exe",
            IconIndex = 2,
            Arguments = "--config test.cfg",
            WorkingDirectory = @"C:\Program Files\App"
        };

        var message = SpiceMessageSerializer.CreateShortcutMessage(info, isNew: true);

        Assert.Equal(info.ShortcutPath, message.ShortcutPath);
        Assert.Equal(info.TargetPath, message.TargetPath);
        Assert.Equal(info.DisplayName, message.DisplayName);
        Assert.Equal(info.IconPath, message.IconPath);
        Assert.Equal(2, message.IconIndex);
        Assert.Equal("--config test.cfg", message.Arguments);
        Assert.Equal(@"C:\Program Files\App", message.WorkingDirectory);
        Assert.True(message.IsNew);
    }

    [Fact]
    public void CreateShortcutMessage_ExistingShortcut_SetsIsNewFalse()
    {
        var info = new ShortcutInfo
        {
            ShortcutPath = @"C:\Test\app.lnk",
            TargetPath = @"C:\App\app.exe",
            DisplayName = "App",
            IconPath = @"C:\App\app.exe"
        };

        var message = SpiceMessageSerializer.CreateShortcutMessage(info, isNew: false);

        Assert.False(message.IsNew);
    }

    [Fact]
    public void SerializeIconDataMessage()
    {
        var message = new IconDataMessage
        {
            ExecutablePath = @"C:\App\app.exe",
            Width = 256,
            Height = 256,
            PngData = [0x89, 0x50, 0x4E, 0x47],
            IconHash = "ABCD1234",
            IconIndex = 0,
            WasScaled = false
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.IconData, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void SerializeShortcutDetectedMessage()
    {
        var message = new ShortcutDetectedMessage
        {
            ShortcutPath = @"C:\Test\app.lnk",
            TargetPath = @"C:\App\app.exe",
            DisplayName = "Test App",
            IconPath = @"C:\App\app.exe",
            IconIndex = 0,
            Arguments = "--test",
            WorkingDirectory = @"C:\App",
            IsNew = true
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.ShortcutDetected, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void DeserializeRequestIconMessage()
    {
        var request = new RequestIconMessage
        {
            MessageId = 200,
            ExecutablePath = @"C:\Program Files\App\app.exe",
            PreferredSize = 512
        };

        var bytes = SerializeHostMessage(SpiceMessageType.RequestIcon, request);
        var result = SpiceMessageSerializer.Deserialize(bytes);

        Assert.NotNull(result);
        var msg = Assert.IsType<RequestIconMessage>(result);
        Assert.Equal(200u, msg.MessageId);
        Assert.Equal(@"C:\Program Files\App\app.exe", msg.ExecutablePath);
        Assert.Equal(512, msg.PreferredSize);
    }

    [Fact]
    public void DeserializeHostClipboardMessage()
    {
        var clipboard = new HostClipboardMessage
        {
            MessageId = 300,
            Format = ClipboardFormat.PlainText,
            Data = System.Text.Encoding.UTF8.GetBytes("Hello, World!"),
            SequenceNumber = 42
        };

        var bytes = SerializeHostMessage(SpiceMessageType.ClipboardData, clipboard);
        var result = SpiceMessageSerializer.Deserialize(bytes);

        Assert.NotNull(result);
        var msg = Assert.IsType<HostClipboardMessage>(result);
        Assert.Equal(300u, msg.MessageId);
        Assert.Equal(ClipboardFormat.PlainText, msg.Format);
        Assert.Equal("Hello, World!", System.Text.Encoding.UTF8.GetString(msg.Data));
        Assert.Equal(42UL, msg.SequenceNumber);
    }

    [Fact]
    public void DeserializeMouseInputMessage()
    {
        var mouse = new MouseInputMessage
        {
            MessageId = 400,
            WindowId = 12345,
            EventType = MouseEventType.Press,
            Button = MouseButton.Left,
            X = 100.5,
            Y = 200.75,
            ScrollDeltaX = 0.0,
            ScrollDeltaY = 0.0,
            Modifiers = KeyModifiers.Control | KeyModifiers.Shift
        };

        var bytes = SerializeHostMessage(SpiceMessageType.MouseInput, mouse);
        var result = SpiceMessageSerializer.Deserialize(bytes);

        Assert.NotNull(result);
        var msg = Assert.IsType<MouseInputMessage>(result);
        Assert.Equal(400u, msg.MessageId);
        Assert.Equal(12345UL, msg.WindowId);
        Assert.Equal(MouseEventType.Press, msg.EventType);
        Assert.Equal(MouseButton.Left, msg.Button);
        Assert.Equal(100.5, msg.X);
        Assert.Equal(200.75, msg.Y);
        Assert.Equal(KeyModifiers.Control | KeyModifiers.Shift, msg.Modifiers);
    }

    [Fact]
    public void DeserializeKeyboardInputMessage()
    {
        var keyboard = new KeyboardInputMessage
        {
            MessageId = 500,
            WindowId = 67890,
            EventType = KeyEventType.KeyDown,
            KeyCode = 65, // 'A'
            ScanCode = 30,
            IsExtendedKey = false,
            Modifiers = KeyModifiers.None,
            Character = "A"
        };

        var bytes = SerializeHostMessage(SpiceMessageType.KeyboardInput, keyboard);
        var result = SpiceMessageSerializer.Deserialize(bytes);

        Assert.NotNull(result);
        var msg = Assert.IsType<KeyboardInputMessage>(result);
        Assert.Equal(500u, msg.MessageId);
        Assert.Equal(67890UL, msg.WindowId);
        Assert.Equal(KeyEventType.KeyDown, msg.EventType);
        Assert.Equal(65u, msg.KeyCode);
        Assert.Equal("A", msg.Character);
    }

    [Fact]
    public void DeserializeDragDropMessage()
    {
        var dragDrop = new DragDropMessage
        {
            MessageId = 600,
            WindowId = 11111,
            EventType = DragDropEventType.Drop,
            X = 150.0,
            Y = 250.0,
            Files =
            [
                new DraggedFileInfo
                {
                    HostPath = "/Users/test/file.txt",
                    GuestPath = @"C:\Users\test\file.txt",
                    FileSize = 1024,
                    IsDirectory = false
                }
            ],
            AllowedOperations = [DragOperation.Copy, DragOperation.Move],
            SelectedOperation = DragOperation.Copy
        };

        var bytes = SerializeHostMessage(SpiceMessageType.DragDropEvent, dragDrop);
        var result = SpiceMessageSerializer.Deserialize(bytes);

        Assert.NotNull(result);
        var msg = Assert.IsType<DragDropMessage>(result);
        Assert.Equal(600u, msg.MessageId);
        Assert.Equal(11111UL, msg.WindowId);
        Assert.Equal(DragDropEventType.Drop, msg.EventType);
        Assert.Equal(150.0, msg.X);
        Assert.Equal(250.0, msg.Y);
        _ = Assert.Single(msg.Files);
        Assert.Equal(2, msg.AllowedOperations.Length);
        Assert.Equal(DragOperation.Copy, msg.SelectedOperation);
    }

    [Fact]
    public void DeserializeReturnsNullForUnknownMessageType()
    {
        var data = new byte[] { 0xFF, 0x00, 0x00, 0x00, 0x00 }; // Invalid type

        var result = SpiceMessageSerializer.Deserialize(data);

        Assert.Null(result);
    }

    [Fact]
    public void DeserializeReturnsNullForIncompleteEnvelope()
    {
        var data = new byte[] { 0x01 }; // Only type byte

        var result = SpiceMessageSerializer.Deserialize(data);

        Assert.Null(result);
    }

    [Fact]
    public void DeserializeReturnsNullForIncompletePayload()
    {
        // Type + length (100 bytes) but only 10 bytes of payload
        var data = new byte[15];
        data[0] = (byte)SpiceMessageType.LaunchProgram;
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(1), 100);

        var result = SpiceMessageSerializer.Deserialize(data);

        Assert.Null(result);
    }

    [Fact]
    public void SerializeWindowMetadataMessage()
    {
        var message = new WindowMetadataMessage
        {
            WindowId = 99999,
            Title = "Test Window",
            Bounds = new RectInfo(10, 20, 800, 600),
            EventType = WindowEventType.Created,
            ProcessId = 1234,
            ClassName = "TestClass",
            IsMinimized = false,
            IsResizable = true,
            ScaleFactor = 1.5
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.WindowMetadata, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void SerializeFrameDataMessage()
    {
        var message = new FrameDataMessage
        {
            WindowId = 55555,
            Width = 1920,
            Height = 1080,
            Stride = 7680,
            Format = PixelFormatType.Bgra32,
            DataLength = 8294400,
            FrameNumber = 100,
            IsKeyFrame = true
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.FrameData, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void SerializeFrameWithSeparateData()
    {
        var header = new FrameDataMessage
        {
            WindowId = 77777,
            Width = 640,
            Height = 480,
            Stride = 2560,
            Format = PixelFormatType.Bgra32,
            DataLength = 1228800,
            FrameNumber = 1,
            IsKeyFrame = true
        };

        var frameData = new byte[640 * 480 * 4]; // BGRA32 = 4 bytes per pixel

        var (headerBytes, dataBytes) = SpiceMessageSerializer.SerializeFrame(header, frameData);

        Assert.Equal((byte)SpiceMessageType.FrameData, headerBytes[0]);
        Assert.Equal(frameData.Length, dataBytes.Length);
    }

    [Fact]
    public void SerializeErrorMessage()
    {
        var message = new ErrorMessage
        {
            Code = "LAUNCH_FAILED",
            Message = "Failed to launch application",
            RelatedMessageId = 12345
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.Error, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void SerializeAckMessage()
    {
        var message = new AckMessage
        {
            MessageId = 999,
            Success = true,
            ErrorMessage = null
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.Ack, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void SerializeAckMessageWithError()
    {
        var message = new AckMessage
        {
            MessageId = 1000,
            Success = false,
            ErrorMessage = "Process not found"
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.Ack, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void SerializeGuestClipboardMessage()
    {
        var message = new GuestClipboardMessage
        {
            Format = ClipboardFormat.Html,
            Data = System.Text.Encoding.UTF8.GetBytes("<html><body>Test</body></html>"),
            SequenceNumber = 100
        };

        var bytes = SpiceMessageSerializer.Serialize(message);

        Assert.Equal((byte)SpiceMessageType.ClipboardChanged, bytes[0]);
        Assert.True(bytes.Length > 5);
    }

    [Fact]
    public void TryReadMessageConsumesCompleteMessage()
    {
        var launch = new LaunchProgramMessage
        {
            MessageId = 42,
            Path = @"C:\test.exe",
            Arguments = []
        };

        var bytes = SerializeHostMessage(SpiceMessageType.LaunchProgram, launch);
        var consumed = SpiceMessageSerializer.TryReadMessage(bytes, out var message);

        Assert.Equal(bytes.Length, consumed);
        Assert.NotNull(message);
        _ = Assert.IsType<LaunchProgramMessage>(message);
    }

    [Fact]
    public void TryReadMessageHandlesMultipleMessages()
    {
        var msg1 = new LaunchProgramMessage { MessageId = 1, Path = @"C:\test1.exe", Arguments = [] };
        var msg2 = new ShutdownMessage { MessageId = 2, TimeoutMs = 5000 };

        var bytes1 = SerializeHostMessage(SpiceMessageType.LaunchProgram, msg1);
        var bytes2 = SerializeHostMessage(SpiceMessageType.Shutdown, msg2);
        var combined = new byte[bytes1.Length + bytes2.Length];
        bytes1.CopyTo(combined, 0);
        bytes2.CopyTo(combined, bytes1.Length);

        var consumed1 = SpiceMessageSerializer.TryReadMessage(combined, out var result1);
        Assert.True(consumed1 > 0);
        Assert.NotNull(result1);

        var remaining = combined.AsSpan(consumed1);
        var consumed2 = SpiceMessageSerializer.TryReadMessage(remaining, out var result2);
        Assert.True(consumed2 > 0);
        Assert.NotNull(result2);
    }

    [Fact]
    public void CreateIconMessage_EmptyData_HandlesGracefully()
    {
        var message = SpiceMessageSerializer.CreateIconMessage(
            @"C:\App\app.exe",
            [],
            width: 0,
            height: 0);

        Assert.Equal(0, message.Width);
        Assert.Equal(0, message.Height);
        Assert.Empty(message.PngData);
    }

    [Fact]
    public void AllClipboardFormatsAreDefined()
    {
        var formats = Enum.GetValues<ClipboardFormat>();

        Assert.Contains(ClipboardFormat.PlainText, formats);
        Assert.Contains(ClipboardFormat.Rtf, formats);
        Assert.Contains(ClipboardFormat.Html, formats);
        Assert.Contains(ClipboardFormat.Png, formats);
        Assert.Contains(ClipboardFormat.Tiff, formats);
        Assert.Contains(ClipboardFormat.FileUrl, formats);
    }

    [Fact]
    public void AllMouseEventTypesAreDefined()
    {
        var types = Enum.GetValues<MouseEventType>();

        Assert.Contains(MouseEventType.Move, types);
        Assert.Contains(MouseEventType.Press, types);
        Assert.Contains(MouseEventType.Release, types);
        Assert.Contains(MouseEventType.Scroll, types);
    }

    [Fact]
    public void AllKeyEventTypesAreDefined()
    {
        var types = Enum.GetValues<KeyEventType>();

        Assert.Contains(KeyEventType.KeyDown, types);
        Assert.Contains(KeyEventType.KeyUp, types);
    }

    [Fact]
    public void AllDragDropEventTypesAreDefined()
    {
        var types = Enum.GetValues<DragDropEventType>();

        Assert.Contains(DragDropEventType.Enter, types);
        Assert.Contains(DragDropEventType.Move, types);
        Assert.Contains(DragDropEventType.Leave, types);
        Assert.Contains(DragDropEventType.Drop, types);
    }

    [Fact]
    public void AllDragOperationsAreDefined()
    {
        var operations = Enum.GetValues<DragOperation>();

        Assert.Contains(DragOperation.None, operations);
        Assert.Contains(DragOperation.Copy, operations);
        Assert.Contains(DragOperation.Move, operations);
        Assert.Contains(DragOperation.Link, operations);
    }

    [Fact]
    public void KeyModifiersCanBeCombined()
    {
        var combined = KeyModifiers.Shift | KeyModifiers.Control | KeyModifiers.Alt;

        Assert.True(combined.HasFlag(KeyModifiers.Shift));
        Assert.True(combined.HasFlag(KeyModifiers.Control));
        Assert.True(combined.HasFlag(KeyModifiers.Alt));
        Assert.False(combined.HasFlag(KeyModifiers.Command));
    }

    [Fact]
    public void GuestCapabilitiesCanBeCombined()
    {
        var combined = GuestCapabilities.WindowTracking | GuestCapabilities.ClipboardSync | GuestCapabilities.IconExtraction;

        Assert.True(combined.HasFlag(GuestCapabilities.WindowTracking));
        Assert.True(combined.HasFlag(GuestCapabilities.ClipboardSync));
        Assert.True(combined.HasFlag(GuestCapabilities.IconExtraction));
        Assert.False(combined.HasFlag(GuestCapabilities.DragDrop));
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

