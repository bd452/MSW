using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

/// <summary>
/// Tests that validate protocol constants match expected values from shared/protocol.def.
/// These tests ensure the generated types have correct values.
/// </summary>
public sealed class ProtocolValidationTests
{
    // ========================================================================
    // Protocol Version
    // ========================================================================

    [Fact]
    public void ProtocolVersionHasExpectedValues()
    {
        // From protocol.def: PROTOCOL_VERSION_MAJOR = 1, PROTOCOL_VERSION_MINOR = 0
        Assert.Equal((ushort)1, SpiceProtocolVersion.Major);
        Assert.Equal((ushort)0, SpiceProtocolVersion.Minor);
        Assert.Equal(0x0001_0000u, SpiceProtocolVersion.Combined);
    }

    // ========================================================================
    // Message Types (Host → Guest)
    // ========================================================================

    [Fact]
    public void HostToGuestMessageTypesHaveExpectedValues()
    {
        // From protocol.def [MESSAGE_TYPES_HOST_TO_GUEST]
        Assert.Equal((byte)0x01, (byte)SpiceMessageType.LaunchProgram);
        Assert.Equal((byte)0x02, (byte)SpiceMessageType.RequestIcon);
        Assert.Equal((byte)0x03, (byte)SpiceMessageType.ClipboardData);
        Assert.Equal((byte)0x04, (byte)SpiceMessageType.MouseInput);
        Assert.Equal((byte)0x05, (byte)SpiceMessageType.KeyboardInput);
        Assert.Equal((byte)0x06, (byte)SpiceMessageType.DragDropEvent);
        Assert.Equal((byte)0x08, (byte)SpiceMessageType.ListSessions);
        Assert.Equal((byte)0x09, (byte)SpiceMessageType.CloseSession);
        Assert.Equal((byte)0x0A, (byte)SpiceMessageType.ListShortcuts);
        Assert.Equal((byte)0x0F, (byte)SpiceMessageType.Shutdown);
    }

    [Fact]
    public void HostToGuestMessagesAreInCorrectRange()
    {
        // Host → Guest messages should be in range 0x00-0x7F
        var hostMessages = new[]
        {
            SpiceMessageType.LaunchProgram, SpiceMessageType.RequestIcon,
            SpiceMessageType.ClipboardData, SpiceMessageType.MouseInput,
            SpiceMessageType.KeyboardInput, SpiceMessageType.DragDropEvent,
            SpiceMessageType.ListSessions, SpiceMessageType.CloseSession,
            SpiceMessageType.ListShortcuts, SpiceMessageType.Shutdown
        };

        foreach (var msg in hostMessages)
        {
            Assert.True((byte)msg < 0x80, $"{msg} should be < 0x80");
        }
    }

    // ========================================================================
    // Message Types (Guest → Host)
    // ========================================================================

    [Fact]
    public void GuestToHostMessageTypesHaveExpectedValues()
    {
        // From protocol.def [MESSAGE_TYPES_GUEST_TO_HOST]
        Assert.Equal((byte)0x80, (byte)SpiceMessageType.WindowMetadata);
        Assert.Equal((byte)0x81, (byte)SpiceMessageType.FrameData);
        Assert.Equal((byte)0x82, (byte)SpiceMessageType.CapabilityFlags);
        Assert.Equal((byte)0x83, (byte)SpiceMessageType.DpiInfo);
        Assert.Equal((byte)0x84, (byte)SpiceMessageType.IconData);
        Assert.Equal((byte)0x85, (byte)SpiceMessageType.ShortcutDetected);
        Assert.Equal((byte)0x86, (byte)SpiceMessageType.ClipboardChanged);
        Assert.Equal((byte)0x87, (byte)SpiceMessageType.Heartbeat);
        Assert.Equal((byte)0x88, (byte)SpiceMessageType.TelemetryReport);
        Assert.Equal((byte)0x89, (byte)SpiceMessageType.ProvisionProgress);
        Assert.Equal((byte)0x8A, (byte)SpiceMessageType.ProvisionError);
        Assert.Equal((byte)0x8B, (byte)SpiceMessageType.ProvisionComplete);
        Assert.Equal((byte)0x8C, (byte)SpiceMessageType.SessionList);
        Assert.Equal((byte)0x8D, (byte)SpiceMessageType.ShortcutList);
        Assert.Equal((byte)0xFE, (byte)SpiceMessageType.Error);
        Assert.Equal((byte)0xFF, (byte)SpiceMessageType.Ack);
    }

    [Fact]
    public void GuestToHostMessagesAreInCorrectRange()
    {
        // Guest → Host messages should be in range 0x80-0xFF
        var guestMessages = new[]
        {
            SpiceMessageType.WindowMetadata, SpiceMessageType.FrameData,
            SpiceMessageType.CapabilityFlags, SpiceMessageType.DpiInfo,
            SpiceMessageType.IconData, SpiceMessageType.ShortcutDetected,
            SpiceMessageType.ClipboardChanged, SpiceMessageType.Heartbeat,
            SpiceMessageType.TelemetryReport, SpiceMessageType.ProvisionProgress,
            SpiceMessageType.ProvisionError, SpiceMessageType.ProvisionComplete,
            SpiceMessageType.SessionList, SpiceMessageType.ShortcutList,
            SpiceMessageType.Error, SpiceMessageType.Ack
        };

        foreach (var msg in guestMessages)
        {
            Assert.True((byte)msg >= 0x80, $"{msg} should be >= 0x80");
        }
    }

    // ========================================================================
    // Guest Capabilities
    // ========================================================================

    [Fact]
    public void CapabilitiesHaveExpectedValues()
    {
        // From protocol.def [CAPABILITIES]
        Assert.Equal(0x01u, (uint)GuestCapabilities.WindowTracking);
        Assert.Equal(0x02u, (uint)GuestCapabilities.DesktopDuplication);
        Assert.Equal(0x04u, (uint)GuestCapabilities.ClipboardSync);
        Assert.Equal(0x08u, (uint)GuestCapabilities.DragDrop);
        Assert.Equal(0x10u, (uint)GuestCapabilities.IconExtraction);
        Assert.Equal(0x20u, (uint)GuestCapabilities.ShortcutDetection);
        Assert.Equal(0x40u, (uint)GuestCapabilities.HighDpiSupport);
        Assert.Equal(0x80u, (uint)GuestCapabilities.MultiMonitor);
    }

    [Fact]
    public void CapabilitiesArePowersOfTwo()
    {
        // Capability flags should be powers of 2 for bitwise combining
        var capabilities = new[]
        {
            GuestCapabilities.WindowTracking, GuestCapabilities.DesktopDuplication,
            GuestCapabilities.ClipboardSync, GuestCapabilities.DragDrop,
            GuestCapabilities.IconExtraction, GuestCapabilities.ShortcutDetection,
            GuestCapabilities.HighDpiSupport, GuestCapabilities.MultiMonitor
        };

        foreach (var cap in capabilities)
        {
            var value = (uint)cap;
            Assert.True((value & (value - 1)) == 0, $"{cap} should be a power of 2");
        }
    }

    // ========================================================================
    // Mouse Input
    // ========================================================================

    [Fact]
    public void MouseButtonsHaveExpectedValues()
    {
        // From protocol.def [MOUSE_BUTTONS]
        Assert.Equal((byte)1, (byte)MouseButton.Left);
        Assert.Equal((byte)2, (byte)MouseButton.Right);
        Assert.Equal((byte)4, (byte)MouseButton.Middle);
        Assert.Equal((byte)5, (byte)MouseButton.Extra1);
        Assert.Equal((byte)6, (byte)MouseButton.Extra2);
    }

    [Fact]
    public void MouseEventTypesHaveExpectedValues()
    {
        // From protocol.def [MOUSE_EVENT_TYPES]
        Assert.Equal((byte)0, (byte)MouseEventType.Move);
        Assert.Equal((byte)1, (byte)MouseEventType.Press);
        Assert.Equal((byte)2, (byte)MouseEventType.Release);
        Assert.Equal((byte)3, (byte)MouseEventType.Scroll);
    }

    // ========================================================================
    // Keyboard Input
    // ========================================================================

    [Fact]
    public void KeyEventTypesHaveExpectedValues()
    {
        // From protocol.def [KEY_EVENT_TYPES]
        Assert.Equal((byte)0, (byte)KeyEventType.KeyDown);
        Assert.Equal((byte)1, (byte)KeyEventType.KeyUp);
    }

    [Fact]
    public void KeyModifiersHaveExpectedValues()
    {
        // From protocol.def [KEY_MODIFIERS]
        Assert.Equal((byte)0x00, (byte)KeyModifiers.None);
        Assert.Equal((byte)0x01, (byte)KeyModifiers.Shift);
        Assert.Equal((byte)0x02, (byte)KeyModifiers.Control);
        Assert.Equal((byte)0x04, (byte)KeyModifiers.Alt);
        Assert.Equal((byte)0x08, (byte)KeyModifiers.Command);
        Assert.Equal((byte)0x10, (byte)KeyModifiers.CapsLock);
        Assert.Equal((byte)0x20, (byte)KeyModifiers.NumLock);
    }

    // ========================================================================
    // Drag and Drop
    // ========================================================================

    [Fact]
    public void DragDropEventTypesHaveExpectedValues()
    {
        // From protocol.def [DRAG_DROP_EVENT_TYPES]
        Assert.Equal((byte)0, (byte)DragDropEventType.Enter);
        Assert.Equal((byte)1, (byte)DragDropEventType.Move);
        Assert.Equal((byte)2, (byte)DragDropEventType.Leave);
        Assert.Equal((byte)3, (byte)DragDropEventType.Drop);
    }

    [Fact]
    public void DragOperationsHaveExpectedValues()
    {
        // From protocol.def [DRAG_OPERATIONS]
        Assert.Equal((byte)0, (byte)DragOperation.None);
        Assert.Equal((byte)1, (byte)DragOperation.Copy);
        Assert.Equal((byte)2, (byte)DragOperation.Move);
        Assert.Equal((byte)3, (byte)DragOperation.Link);
    }

    // ========================================================================
    // Pixel Formats
    // ========================================================================

    [Fact]
    public void PixelFormatsHaveExpectedValues()
    {
        // From protocol.def [PIXEL_FORMATS]
        Assert.Equal((byte)0, (byte)PixelFormatType.Bgra32);
        Assert.Equal((byte)1, (byte)PixelFormatType.Rgba32);
    }

    // ========================================================================
    // Window Events
    // ========================================================================

    [Fact]
    public void WindowEventTypesHaveExpectedValues()
    {
        // From protocol.def [WINDOW_EVENT_TYPES]
        Assert.Equal(0, (int)WindowEventType.Created);
        Assert.Equal(1, (int)WindowEventType.Destroyed);
        Assert.Equal(2, (int)WindowEventType.Moved);
        Assert.Equal(3, (int)WindowEventType.TitleChanged);
        Assert.Equal(4, (int)WindowEventType.FocusChanged);
        Assert.Equal(5, (int)WindowEventType.Minimized);
        Assert.Equal(6, (int)WindowEventType.Restored);
        Assert.Equal(7, (int)WindowEventType.Updated);
    }

    // ========================================================================
    // Clipboard Formats
    // ========================================================================

    [Fact]
    public void ClipboardFormatsExist()
    {
        // From protocol.def [CLIPBOARD_FORMATS] - verify all formats are defined
        Assert.True(Enum.IsDefined(typeof(ClipboardFormat), ClipboardFormat.PlainText));
        Assert.True(Enum.IsDefined(typeof(ClipboardFormat), ClipboardFormat.Rtf));
        Assert.True(Enum.IsDefined(typeof(ClipboardFormat), ClipboardFormat.Html));
        Assert.True(Enum.IsDefined(typeof(ClipboardFormat), ClipboardFormat.Png));
        Assert.True(Enum.IsDefined(typeof(ClipboardFormat), ClipboardFormat.Tiff));
        Assert.True(Enum.IsDefined(typeof(ClipboardFormat), ClipboardFormat.FileUrl));
    }

    // ========================================================================
    // Provisioning Phases
    // ========================================================================

    [Fact]
    public void ProvisioningPhasesExist()
    {
        // From protocol.def [PROVISIONING_PHASES] - verify all phases are defined
        Assert.True(Enum.IsDefined(typeof(ProvisioningPhase), ProvisioningPhase.Drivers));
        Assert.True(Enum.IsDefined(typeof(ProvisioningPhase), ProvisioningPhase.Agent));
        Assert.True(Enum.IsDefined(typeof(ProvisioningPhase), ProvisioningPhase.Optimize));
        Assert.True(Enum.IsDefined(typeof(ProvisioningPhase), ProvisioningPhase.Finalize));
        Assert.True(Enum.IsDefined(typeof(ProvisioningPhase), ProvisioningPhase.Complete));
    }

    // ========================================================================
    // Completeness
    // ========================================================================

    [Fact]
    public void AllMessageTypesAreCovered()
    {
        // Ensure we haven't added message types without adding tests
        var allValues = Enum.GetValues<SpiceMessageType>();
        Assert.Equal(26, allValues.Length);
    }
}
