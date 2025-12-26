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
public static class SpiceProtocolVersion
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
public enum SpiceMessageType : byte
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
    FrameReady = 0x8E,
    WindowBufferAllocated = 0x8F,
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
public enum GuestCapabilities : uint
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
public enum MouseButton : byte
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
public enum MouseEventType : byte
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
public enum KeyEventType : byte
{
    KeyDown = 0,
    KeyUp = 1,
}

/// <summary>
/// Key modifier flags - generated from shared/protocol.def
/// </summary>
[Flags]
public enum KeyModifiers : byte
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
public enum DragDropEventType : byte
{
    Enter = 0,
    Move = 1,
    Leave = 2,
    Drop = 3,
}

/// <summary>
/// Drag operation types - generated from shared/protocol.def
/// </summary>
public enum DragOperation : byte
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
public enum PixelFormatType : byte
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
public enum WindowEventType : int
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
public enum ClipboardFormat
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
public enum ProvisioningPhase
{
    Drivers,
    Agent,
    Optimize,
    Finalize,
    Complete,
}

// ============================================================================
// Backwards Compatibility Aliases
// ============================================================================
// These allow existing code referencing Generated* types to continue working
// TODO: Remove these after migrating all code to use the canonical type names

#pragma warning disable CA1711 // Identifiers should not have incorrect suffix

/// <summary>Backwards compatibility alias - use SpiceProtocolVersion instead</summary>
[Obsolete("Use SpiceProtocolVersion instead")]
public static class GeneratedProtocolVersion
{
    public const ushort Major = SpiceProtocolVersion.Major;
    public const ushort Minor = SpiceProtocolVersion.Minor;
    public static uint Combined => SpiceProtocolVersion.Combined;
}

/// <summary>Backwards compatibility alias - use SpiceMessageType instead</summary>
[Obsolete("Use SpiceMessageType instead")]
public enum GeneratedMessageType : byte
{
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
    FrameReady = 0x8E,
    WindowBufferAllocated = 0x8F,
    Error = 0xFE,
    Ack = 0xFF,
}

/// <summary>Backwards compatibility alias - use GuestCapabilities instead</summary>
[Obsolete("Use GuestCapabilities instead")]
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

#pragma warning restore CA1711
#pragma warning restore CA1008
