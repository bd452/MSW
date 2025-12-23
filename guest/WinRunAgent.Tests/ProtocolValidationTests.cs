using WinRun.Agent.Services;
using Xunit;

namespace WinRun.Agent.Tests;

/// <summary>
/// Tests that validate existing protocol constants match the generated source of truth.
/// These tests ensure the existing types stay in sync with shared/protocol.def.
/// </summary>
public sealed class ProtocolValidationTests
{
    // ========================================================================
    // Protocol Version
    // ========================================================================

    [Fact]
    public void ProtocolVersionMatchesGenerated()
    {
        Assert.Equal(GeneratedProtocolVersion.Major, ProtocolVersion.Major);
        Assert.Equal(GeneratedProtocolVersion.Minor, ProtocolVersion.Minor);
        Assert.Equal(GeneratedProtocolVersion.Combined, ProtocolVersion.Combined);
    }

    // ========================================================================
    // Message Types
    // ========================================================================

    [Fact]
    public void HostToGuestMessageTypesMatchGenerated()
    {
        Assert.Equal((byte)GeneratedMessageType.LaunchProgram, (byte)SpiceMessageType.LaunchProgram);
        Assert.Equal((byte)GeneratedMessageType.RequestIcon, (byte)SpiceMessageType.RequestIcon);
        Assert.Equal((byte)GeneratedMessageType.ClipboardData, (byte)SpiceMessageType.ClipboardData);
        Assert.Equal((byte)GeneratedMessageType.MouseInput, (byte)SpiceMessageType.MouseInput);
        Assert.Equal((byte)GeneratedMessageType.KeyboardInput, (byte)SpiceMessageType.KeyboardInput);
        Assert.Equal((byte)GeneratedMessageType.DragDropEvent, (byte)SpiceMessageType.DragDropEvent);
        Assert.Equal((byte)GeneratedMessageType.ListSessions, (byte)SpiceMessageType.ListSessions);
        Assert.Equal((byte)GeneratedMessageType.CloseSession, (byte)SpiceMessageType.CloseSession);
        Assert.Equal((byte)GeneratedMessageType.ListShortcuts, (byte)SpiceMessageType.ListShortcuts);
        Assert.Equal((byte)GeneratedMessageType.Shutdown, (byte)SpiceMessageType.Shutdown);
    }

    [Fact]
    public void GuestToHostMessageTypesMatchGenerated()
    {
        Assert.Equal((byte)GeneratedMessageType.WindowMetadata, (byte)SpiceMessageType.WindowMetadata);
        Assert.Equal((byte)GeneratedMessageType.FrameData, (byte)SpiceMessageType.FrameData);
        Assert.Equal((byte)GeneratedMessageType.CapabilityFlags, (byte)SpiceMessageType.CapabilityFlags);
        Assert.Equal((byte)GeneratedMessageType.DpiInfo, (byte)SpiceMessageType.DpiInfo);
        Assert.Equal((byte)GeneratedMessageType.IconData, (byte)SpiceMessageType.IconData);
        Assert.Equal((byte)GeneratedMessageType.ShortcutDetected, (byte)SpiceMessageType.ShortcutDetected);
        Assert.Equal((byte)GeneratedMessageType.ClipboardChanged, (byte)SpiceMessageType.ClipboardChanged);
        Assert.Equal((byte)GeneratedMessageType.Heartbeat, (byte)SpiceMessageType.Heartbeat);
        Assert.Equal((byte)GeneratedMessageType.TelemetryReport, (byte)SpiceMessageType.TelemetryReport);
        Assert.Equal((byte)GeneratedMessageType.ProvisionProgress, (byte)SpiceMessageType.ProvisionProgress);
        Assert.Equal((byte)GeneratedMessageType.ProvisionError, (byte)SpiceMessageType.ProvisionError);
        Assert.Equal((byte)GeneratedMessageType.ProvisionComplete, (byte)SpiceMessageType.ProvisionComplete);
        Assert.Equal((byte)GeneratedMessageType.SessionList, (byte)SpiceMessageType.SessionList);
        Assert.Equal((byte)GeneratedMessageType.ShortcutList, (byte)SpiceMessageType.ShortcutList);
        Assert.Equal((byte)GeneratedMessageType.Error, (byte)SpiceMessageType.Error);
        Assert.Equal((byte)GeneratedMessageType.Ack, (byte)SpiceMessageType.Ack);
    }

    // ========================================================================
    // Guest Capabilities
    // ========================================================================

    [Fact]
    public void CapabilitiesMatchGenerated()
    {
        Assert.Equal((uint)GeneratedCapabilities.WindowTracking, (uint)GuestCapabilities.WindowTracking);
        Assert.Equal((uint)GeneratedCapabilities.DesktopDuplication, (uint)GuestCapabilities.DesktopDuplication);
        Assert.Equal((uint)GeneratedCapabilities.ClipboardSync, (uint)GuestCapabilities.ClipboardSync);
        Assert.Equal((uint)GeneratedCapabilities.DragDrop, (uint)GuestCapabilities.DragDrop);
        Assert.Equal((uint)GeneratedCapabilities.IconExtraction, (uint)GuestCapabilities.IconExtraction);
        Assert.Equal((uint)GeneratedCapabilities.ShortcutDetection, (uint)GuestCapabilities.ShortcutDetection);
        Assert.Equal((uint)GeneratedCapabilities.HighDpiSupport, (uint)GuestCapabilities.HighDpiSupport);
        Assert.Equal((uint)GeneratedCapabilities.MultiMonitor, (uint)GuestCapabilities.MultiMonitor);
    }

    // ========================================================================
    // Mouse Input
    // ========================================================================

    [Fact]
    public void MouseButtonsMatchGenerated()
    {
        Assert.Equal((byte)GeneratedMouseButton.Left, (byte)MouseButton.Left);
        Assert.Equal((byte)GeneratedMouseButton.Right, (byte)MouseButton.Right);
        Assert.Equal((byte)GeneratedMouseButton.Middle, (byte)MouseButton.Middle);
        Assert.Equal((byte)GeneratedMouseButton.Extra1, (byte)MouseButton.Extra1);
        Assert.Equal((byte)GeneratedMouseButton.Extra2, (byte)MouseButton.Extra2);
    }

    [Fact]
    public void MouseEventTypesMatchGenerated()
    {
        Assert.Equal((byte)GeneratedMouseEventType.Move, (byte)MouseEventType.Move);
        Assert.Equal((byte)GeneratedMouseEventType.Press, (byte)MouseEventType.Press);
        Assert.Equal((byte)GeneratedMouseEventType.Release, (byte)MouseEventType.Release);
        Assert.Equal((byte)GeneratedMouseEventType.Scroll, (byte)MouseEventType.Scroll);
    }

    // ========================================================================
    // Keyboard Input
    // ========================================================================

    [Fact]
    public void KeyEventTypesMatchGenerated()
    {
        Assert.Equal((byte)GeneratedKeyEventType.Down, (byte)KeyEventType.KeyDown);
        Assert.Equal((byte)GeneratedKeyEventType.Up, (byte)KeyEventType.KeyUp);
    }

    [Fact]
    public void KeyModifiersMatchGenerated()
    {
        Assert.Equal((byte)GeneratedKeyModifiers.None, (byte)KeyModifiers.None);
        Assert.Equal((byte)GeneratedKeyModifiers.Shift, (byte)KeyModifiers.Shift);
        Assert.Equal((byte)GeneratedKeyModifiers.Control, (byte)KeyModifiers.Control);
        Assert.Equal((byte)GeneratedKeyModifiers.Alt, (byte)KeyModifiers.Alt);
        Assert.Equal((byte)GeneratedKeyModifiers.Command, (byte)KeyModifiers.Command);
        Assert.Equal((byte)GeneratedKeyModifiers.CapsLock, (byte)KeyModifiers.CapsLock);
        Assert.Equal((byte)GeneratedKeyModifiers.NumLock, (byte)KeyModifiers.NumLock);
    }

    // ========================================================================
    // Drag and Drop
    // ========================================================================

    [Fact]
    public void DragDropEventTypesMatchGenerated()
    {
        Assert.Equal((byte)GeneratedDragDropEventType.Enter, (byte)DragDropEventType.Enter);
        Assert.Equal((byte)GeneratedDragDropEventType.Move, (byte)DragDropEventType.Move);
        Assert.Equal((byte)GeneratedDragDropEventType.Leave, (byte)DragDropEventType.Leave);
        Assert.Equal((byte)GeneratedDragDropEventType.Drop, (byte)DragDropEventType.Drop);
    }

    [Fact]
    public void DragOperationsMatchGenerated()
    {
        Assert.Equal((byte)GeneratedDragOperation.None, (byte)DragOperation.None);
        Assert.Equal((byte)GeneratedDragOperation.Copy, (byte)DragOperation.Copy);
        Assert.Equal((byte)GeneratedDragOperation.Move, (byte)DragOperation.Move);
        Assert.Equal((byte)GeneratedDragOperation.Link, (byte)DragOperation.Link);
    }

    // ========================================================================
    // Other Types
    // ========================================================================

    [Fact]
    public void PixelFormatsMatchGenerated()
    {
        Assert.Equal((byte)GeneratedPixelFormat.Bgra32, (byte)PixelFormatType.Bgra32);
        Assert.Equal((byte)GeneratedPixelFormat.Rgba32, (byte)PixelFormatType.Rgba32);
    }

    [Fact]
    public void WindowEventTypesMatchGenerated()
    {
        Assert.Equal((int)GeneratedWindowEventType.Created, (int)WindowEventType.Created);
        Assert.Equal((int)GeneratedWindowEventType.Destroyed, (int)WindowEventType.Destroyed);
        Assert.Equal((int)GeneratedWindowEventType.Moved, (int)WindowEventType.Moved);
        Assert.Equal((int)GeneratedWindowEventType.TitleChanged, (int)WindowEventType.TitleChanged);
        Assert.Equal((int)GeneratedWindowEventType.FocusChanged, (int)WindowEventType.FocusChanged);
        Assert.Equal((int)GeneratedWindowEventType.Minimized, (int)WindowEventType.Minimized);
        Assert.Equal((int)GeneratedWindowEventType.Restored, (int)WindowEventType.Restored);
        Assert.Equal((int)GeneratedWindowEventType.Updated, (int)WindowEventType.Updated);
    }

    [Fact]
    public void ClipboardFormatsMatchGenerated()
    {
        // ClipboardFormat uses JsonStringEnumConverter, so compare string names
        Assert.Equal(GeneratedClipboardFormat.PlainText.ToString(), ClipboardFormat.PlainText.ToString());
        Assert.Equal(GeneratedClipboardFormat.Rtf.ToString(), ClipboardFormat.Rtf.ToString());
        Assert.Equal(GeneratedClipboardFormat.Html.ToString(), ClipboardFormat.Html.ToString());
        Assert.Equal(GeneratedClipboardFormat.Png.ToString(), ClipboardFormat.Png.ToString());
        Assert.Equal(GeneratedClipboardFormat.Tiff.ToString(), ClipboardFormat.Tiff.ToString());
        Assert.Equal(GeneratedClipboardFormat.FileUrl.ToString(), ClipboardFormat.FileUrl.ToString());
    }

    [Fact]
    public void ProvisioningPhasesMatchGenerated()
    {
        // ProvisioningPhase uses JsonStringEnumConverter, so compare string names
        Assert.Equal(GeneratedProvisioningPhase.Drivers.ToString(), ProvisioningPhase.Drivers.ToString());
        Assert.Equal(GeneratedProvisioningPhase.Agent.ToString(), ProvisioningPhase.Agent.ToString());
        Assert.Equal(GeneratedProvisioningPhase.Optimize.ToString(), ProvisioningPhase.Optimize.ToString());
        Assert.Equal(GeneratedProvisioningPhase.Finalize.ToString(), ProvisioningPhase.Finalize.ToString());
        Assert.Equal(GeneratedProvisioningPhase.Complete.ToString(), ProvisioningPhase.Complete.ToString());
    }
}
