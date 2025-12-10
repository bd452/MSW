import Foundation

// MARK: - Mouse Events

/// Mouse button identifiers matching Windows VK codes
public enum MouseButton: Int32, Codable, Hashable {
    case left = 1
    case right = 2
    case middle = 4
    case extra1 = 5
    case extra2 = 6
}

/// Mouse event types for Spice input channel
public enum MouseEventType: Int32, Codable, Hashable {
    case move = 0
    case press = 1
    case release = 2
    case scroll = 3
}

/// A mouse input event to be forwarded to the Windows guest
public struct MouseInputEvent: Codable, Hashable {
    /// Target window ID (0 for global)
    public let windowID: UInt64

    /// Event type (move, press, release, scroll)
    public let eventType: MouseEventType

    /// Mouse button involved (nil for move events)
    public let button: MouseButton?

    /// X position in window coordinates (pixels)
    public let x: Double

    /// Y position in window coordinates (pixels)
    public let y: Double

    /// Scroll delta for scroll events (positive = up/right)
    public let scrollDeltaX: Double

    /// Scroll delta for scroll events (positive = up)
    public let scrollDeltaY: Double

    /// Modifier keys held during the event
    public let modifiers: KeyModifiers

    public init(
        windowID: UInt64,
        eventType: MouseEventType,
        button: MouseButton? = nil,
        x: Double,
        y: Double,
        scrollDeltaX: Double = 0,
        scrollDeltaY: Double = 0,
        modifiers: KeyModifiers = []
    ) {
        self.windowID = windowID
        self.eventType = eventType
        self.button = button
        self.x = x
        self.y = y
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.modifiers = modifiers
    }
}

// MARK: - Keyboard Events

/// Keyboard event types
public enum KeyEventType: Int32, Codable, Hashable {
    case keyDown = 0
    case keyUp = 1
}

/// Modifier key flags
public struct KeyModifiers: OptionSet, Codable, Hashable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let alt = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)  // Maps to Windows key
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let numLock = KeyModifiers(rawValue: 1 << 5)
}

/// A keyboard input event to be forwarded to the Windows guest
public struct KeyboardInputEvent: Codable, Hashable {
    /// Target window ID (0 for global)
    public let windowID: UInt64

    /// Event type (key down or key up)
    public let eventType: KeyEventType

    /// Virtual key code (Windows VK code)
    public let keyCode: UInt32

    /// Hardware scan code
    public let scanCode: UInt32

    /// Whether this is an extended key (right Ctrl, arrow keys, etc.)
    public let isExtendedKey: Bool

    /// Modifier keys held during the event
    public let modifiers: KeyModifiers

    /// Unicode character if applicable (for text input)
    public let character: String?

    public init(
        windowID: UInt64,
        eventType: KeyEventType,
        keyCode: UInt32,
        scanCode: UInt32 = 0,
        isExtendedKey: Bool = false,
        modifiers: KeyModifiers = [],
        character: String? = nil
    ) {
        self.windowID = windowID
        self.eventType = eventType
        self.keyCode = keyCode
        self.scanCode = scanCode
        self.isExtendedKey = isExtendedKey
        self.modifiers = modifiers
        self.character = character
    }
}

// MARK: - Clipboard

/// Supported clipboard data formats
public enum ClipboardFormat: String, Codable, Hashable, CaseIterable {
    case plainText = "public.plain-text"
    case rtf = "public.rtf"
    case html = "public.html"
    case png = "public.png"
    case tiff = "public.tiff"
    case fileURL = "public.file-url"
}

/// Direction of clipboard synchronization
public enum ClipboardDirection: Int32, Codable, Hashable {
    case hostToGuest = 0
    case guestToHost = 1
}

/// Clipboard data to be synchronized between host and guest
public struct ClipboardData: Codable, Hashable {
    /// The format of the clipboard content
    public let format: ClipboardFormat

    /// The actual data (encoded appropriately for the format)
    public let data: Data

    /// Sequence number for ordering/deduplication
    public let sequenceNumber: UInt64

    public init(format: ClipboardFormat, data: Data, sequenceNumber: UInt64 = 0) {
        self.format = format
        self.data = data
        self.sequenceNumber = sequenceNumber
    }

    /// Create clipboard data from a string
    public static func text(_ string: String, sequenceNumber: UInt64 = 0) -> ClipboardData? {
        guard let data = string.data(using: .utf8) else { return nil }
        return ClipboardData(format: .plainText, data: data, sequenceNumber: sequenceNumber)
    }

    /// Extract text content if format is plainText
    public var textContent: String? {
        guard format == .plainText else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A clipboard synchronization event
public struct ClipboardEvent: Codable, Hashable {
    /// Direction of the sync
    public let direction: ClipboardDirection

    /// Available formats (best format first)
    public let availableFormats: [ClipboardFormat]

    /// The clipboard data for the preferred format
    public let content: ClipboardData?

    public init(
        direction: ClipboardDirection,
        availableFormats: [ClipboardFormat],
        content: ClipboardData? = nil
    ) {
        self.direction = direction
        self.availableFormats = availableFormats
        self.content = content
    }
}

// MARK: - Drag and Drop

/// Drag operation types
public enum DragOperation: Int32, Codable, Hashable {
    case none = 0
    case copy = 1
    case move = 2
    case link = 3
}

/// Drag and drop event types
public enum DragDropEventType: Int32, Codable, Hashable {
    case enter = 0
    case move = 1
    case leave = 2
    case drop = 3
}

/// A file being dragged
public struct DraggedFile: Codable, Hashable {
    /// macOS path (e.g., /Users/name/file.txt)
    public let hostPath: String

    /// Translated Windows path (e.g., Z:\file.txt)
    public let guestPath: String?

    /// File size in bytes
    public let fileSize: UInt64

    /// Whether this is a directory
    public let isDirectory: Bool

    public init(hostPath: String, guestPath: String? = nil, fileSize: UInt64 = 0, isDirectory: Bool = false) {
        self.hostPath = hostPath
        self.guestPath = guestPath
        self.fileSize = fileSize
        self.isDirectory = isDirectory
    }
}

/// A drag and drop event
public struct DragDropEvent: Codable, Hashable {
    /// Target window ID
    public let windowID: UInt64

    /// Event type
    public let eventType: DragDropEventType

    /// Current position in window coordinates
    public let x: Double
    public let y: Double

    /// Files being dragged (populated for enter and drop events)
    public let files: [DraggedFile]

    /// Allowed operations (set by enter handler)
    public let allowedOperations: [DragOperation]

    /// Selected operation (for drop events)
    public let selectedOperation: DragOperation?

    public init(
        windowID: UInt64,
        eventType: DragDropEventType,
        x: Double,
        y: Double,
        files: [DraggedFile] = [],
        allowedOperations: [DragOperation] = [.copy],
        selectedOperation: DragOperation? = nil
    ) {
        self.windowID = windowID
        self.eventType = eventType
        self.x = x
        self.y = y
        self.files = files
        self.allowedOperations = allowedOperations
        self.selectedOperation = selectedOperation
    }
}

// MARK: - Key Code Mapping

/// Utility for converting macOS key codes to Windows virtual key codes
public struct KeyCodeMapper {
    /// Convert a macOS virtual key code to Windows VK code
    public static func windowsKeyCode(fromMacOS macKeyCode: UInt16) -> UInt32 {
        return macToWindowsKeyMap[macKeyCode] ?? UInt32(macKeyCode)
    }

    /// Convert macOS modifier flags to KeyModifiers
    public static func modifiers(fromMacOS flags: UInt) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags & (1 << 17) != 0 { result.insert(.shift) }      // NSEvent.ModifierFlags.shift
        if flags & (1 << 18) != 0 { result.insert(.control) }    // NSEvent.ModifierFlags.control
        if flags & (1 << 19) != 0 { result.insert(.alt) }        // NSEvent.ModifierFlags.option
        if flags & (1 << 20) != 0 { result.insert(.command) }    // NSEvent.ModifierFlags.command
        if flags & (1 << 16) != 0 { result.insert(.capsLock) }   // NSEvent.ModifierFlags.capsLock
        return result
    }

    // Common macOS key code to Windows VK code mappings
    private static let macToWindowsKeyMap: [UInt16: UInt32] = [
        // Letters (A-Z: VK 0x41-0x5A)
        0x00: 0x41, // A
        0x0B: 0x42, // B
        0x08: 0x43, // C
        0x02: 0x44, // D
        0x0E: 0x45, // E
        0x03: 0x46, // F
        0x05: 0x47, // G
        0x04: 0x48, // H
        0x22: 0x49, // I
        0x26: 0x4A, // J
        0x28: 0x4B, // K
        0x25: 0x4C, // L
        0x2E: 0x4D, // M
        0x2D: 0x4E, // N
        0x1F: 0x4F, // O
        0x23: 0x50, // P
        0x0C: 0x51, // Q
        0x0F: 0x52, // R
        0x01: 0x53, // S
        0x11: 0x54, // T
        0x20: 0x55, // U
        0x09: 0x56, // V
        0x0D: 0x57, // W
        0x07: 0x58, // X
        0x10: 0x59, // Y
        0x06: 0x5A, // Z

        // Numbers (0-9: VK 0x30-0x39)
        0x1D: 0x30, // 0
        0x12: 0x31, // 1
        0x13: 0x32, // 2
        0x14: 0x33, // 3
        0x15: 0x34, // 4
        0x17: 0x35, // 5
        0x16: 0x36, // 6
        0x1A: 0x37, // 7
        0x1C: 0x38, // 8
        0x19: 0x39, // 9

        // Function keys
        0x7A: 0x70, // F1
        0x78: 0x71, // F2
        0x63: 0x72, // F3
        0x76: 0x73, // F4
        0x60: 0x74, // F5
        0x61: 0x75, // F6
        0x62: 0x76, // F7
        0x64: 0x77, // F8
        0x65: 0x78, // F9
        0x6D: 0x79, // F10
        0x67: 0x7A, // F11
        0x6F: 0x7B, // F12

        // Special keys
        0x24: 0x0D, // Return -> VK_RETURN
        0x30: 0x09, // Tab -> VK_TAB
        0x31: 0x20, // Space -> VK_SPACE
        0x33: 0x08, // Delete -> VK_BACK
        0x35: 0x1B, // Escape -> VK_ESCAPE
        0x75: 0x2E, // Forward Delete -> VK_DELETE
        0x73: 0x24, // Home -> VK_HOME
        0x77: 0x23, // End -> VK_END
        0x74: 0x21, // Page Up -> VK_PRIOR
        0x79: 0x22, // Page Down -> VK_NEXT

        // Arrow keys
        0x7B: 0x25, // Left -> VK_LEFT
        0x7C: 0x27, // Right -> VK_RIGHT
        0x7E: 0x26, // Up -> VK_UP
        0x7D: 0x28, // Down -> VK_DOWN

        // Modifiers
        0x38: 0x10, // Shift -> VK_SHIFT
        0x3B: 0x11, // Control -> VK_CONTROL
        0x3A: 0x12, // Option -> VK_MENU (Alt)
        0x37: 0x5B, // Command -> VK_LWIN
    ]
}
