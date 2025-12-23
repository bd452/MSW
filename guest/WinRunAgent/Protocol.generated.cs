// Protocol.generated.cs
// AUTO-GENERATED FROM shared/protocol.def - DO NOT EDIT DIRECTLY
//
// To regenerate: make generate-protocol
// Source of truth: shared/protocol.def

namespace WinRun.Agent.Services;

#pragma warning disable CA1008 // Enums should have zero value

// ============================================================================
// Protocol Version
// ============================================================================

/// <summary>
/// Protocol version constants - generated from shared/protocol.def
/// </summary>
public static class GeneratedProtocolVersion
{
    public const ushort Major = 1;
    public const ushort Minor = 0;
    public static uint Combined => ((uint)Major << 16) | Minor;
}

// ============================================================================
// Message Types
// ============================================================================

/// <summary>
/// Message type codes - generated from shared/protocol.def
/// </summary>
public enum GeneratedMessageType : byte
{
    // Host → Guest (0x00-0x7F)
    LaunchProgram = 0x01,
    RequestIcon = 0x02,
    ClipboardData = 0x03,
    MouseInput = 0x04,
    KeyboardInput = 0x05,
    DragDropEvent = 0x06,
    ListSessions = 0x08,
    CloseSession = 0x09,
    ListShortcuts = 0x0A,
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
    TelemetryReport = 0x88,
    ProvisionProgress = 0x89,
    ProvisionError = 0x8A,
    ProvisionComplete = 0x8B,
    SessionList = 0x8C,
    ShortcutList = 0x8D,
    Error = 0xFE,
    Ack = 0xFF,
}

// ============================================================================
// Guest Capabilities
// ============================================================================

/// <summary>
/// Guest capability flags - generated from shared/protocol.def
/// </summary>
[Flags]
public enum GeneratedCapabilities : uint
{
    None = 0,
    WindowTracking = 0x01,
    DesktopDuplication = 0x02,
    ClipboardSync = 0x04,
    DragDrop = 0x08,
    IconExtraction = 0x10,
    ShortcutDetection = 0x20,
    HighDpiSupport = 0x40,
    MultiMonitor = 0x80,
}

// ============================================================================
// Mouse Input
// ============================================================================

/// <summary>
/// Mouse button codes - generated from shared/protocol.def
/// </summary>
public enum GeneratedMouseButton : byte
{
    Left = 1,
    Right = 2,
    Middle = 4,
    Extra1 = 5,
    Extra2 = 6,
}

/// <summary>
/// Mouse event types - generated from shared/protocol.def
/// </summary>
public enum GeneratedMouseEventType : byte
{
    Move = 0,
    Press = 1,
    Release = 2,
    Scroll = 3,
}

// ============================================================================
// Keyboard Input
// ============================================================================

/// <summary>
/// Key event types - generated from shared/protocol.def
/// </summary>
public enum GeneratedKeyEventType : byte
{
    Down = 0,
    Up = 1,
}

/// <summary>
/// Key modifier flags - generated from shared/protocol.def
/// </summary>
[Flags]
public enum GeneratedKeyModifiers : byte
{
    None = 0x00,
    Shift = 0x01,
    Control = 0x02,
    Alt = 0x04,
    Command = 0x08,
    CapsLock = 0x10,
    NumLock = 0x20,
}

// ============================================================================
// Drag and Drop
// ============================================================================

/// <summary>
/// Drag/drop event types - generated from shared/protocol.def
/// </summary>
public enum GeneratedDragDropEventType : byte
{
    Enter = 0,
    Move = 1,
    Leave = 2,
    Drop = 3,
}

/// <summary>
/// Drag operation types - generated from shared/protocol.def
/// </summary>
public enum GeneratedDragOperation : byte
{
    None = 0,
    Copy = 1,
    Move = 2,
    Link = 3,
}

// ============================================================================
// Pixel Formats
// ============================================================================

/// <summary>
/// Pixel format types - generated from shared/protocol.def
/// </summary>
public enum GeneratedPixelFormat : byte
{
    Bgra32 = 0,
    Rgba32 = 1,
}

// ============================================================================
// Window Events
// ============================================================================

/// <summary>
/// Window event types - generated from shared/protocol.def
/// </summary>
public enum GeneratedWindowEventType : int
{
    Created = 0,
    Destroyed = 1,
    Moved = 2,
    TitleChanged = 3,
    FocusChanged = 4,
    Minimized = 5,
    Restored = 6,
    Updated = 7,
}

// ============================================================================
// Clipboard Formats
// ============================================================================

/// <summary>
/// Clipboard format identifiers - generated from shared/protocol.def
/// </summary>
public enum GeneratedClipboardFormat
{
    PlainText,
    Rtf,
    Html,
    Png,
    Tiff,
    FileUrl,
}

// ============================================================================
// Provisioning Phases
// ============================================================================

/// <summary>
/// Provisioning phase identifiers - generated from shared/protocol.def
/// </summary>
public enum GeneratedProvisioningPhase
{
    Drivers,
    Agent,
    Optimize,
    Finalize,
    Complete,
}

#pragma warning restore CA1008
