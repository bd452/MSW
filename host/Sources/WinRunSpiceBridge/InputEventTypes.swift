import Foundation

// MARK: - Mouse Events
// Note: MouseButton, MouseEventType are defined in Protocol.generated.swift

/// A mouse input event to be forwarded to the Windows guest
public struct MouseInputEvent: Codable, Hashable, Sendable {
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
// Note: KeyEventType, KeyModifiers are defined in Protocol.generated.swift

/// A keyboard input event to be forwarded to the Windows guest
public struct KeyboardInputEvent: Codable, Hashable, Sendable {
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

// MARK: - Drag and Drop
// Note: DragDropEventType, DragOperation are defined in Protocol.generated.swift

/// A file being dragged
public struct DraggedFile: Codable, Hashable, Sendable {
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
public struct DragDropEvent: Codable, Hashable, Sendable {
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
