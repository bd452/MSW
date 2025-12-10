import Foundation
import WinRunShared

// MARK: - Host Message Protocol

/// Base protocol for messages sent to guest.
public protocol HostMessage: Codable {
    /// Unique message ID for acknowledgement tracking
    var messageId: UInt32 { get }
}

// MARK: - Host → Guest Messages

/// Request to launch a program on the guest.
public struct LaunchProgramSpiceMessage: HostMessage {
    public let messageId: UInt32
    public let path: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let environment: [String: String]?

    public init(
        messageId: UInt32,
        path: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.messageId = messageId
        self.path = path
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// Request to extract and send an icon for an executable.
public struct RequestIconSpiceMessage: HostMessage {
    public let messageId: UInt32
    public let executablePath: String
    public let preferredSize: Int32

    public init(messageId: UInt32, executablePath: String, preferredSize: Int32 = 256) {
        self.messageId = messageId
        self.executablePath = executablePath
        self.preferredSize = preferredSize
    }
}

/// Clipboard data from host to guest.
public struct HostClipboardSpiceMessage: HostMessage {
    public let messageId: UInt32
    public let format: ClipboardFormat
    public let data: Data
    public let sequenceNumber: UInt64

    public init(messageId: UInt32, format: ClipboardFormat, data: Data, sequenceNumber: UInt64 = 0) {
        self.messageId = messageId
        self.format = format
        self.data = data
        self.sequenceNumber = sequenceNumber
    }
}

/// Mouse input event from host.
public struct MouseInputSpiceMessage: HostMessage {
    public let messageId: UInt32
    public let windowId: UInt64
    public let eventType: MouseEventType
    public let button: MouseButton?
    public let x: Double
    public let y: Double
    public let scrollDeltaX: Double
    public let scrollDeltaY: Double
    public let modifiers: KeyModifiers

    public init(
        messageId: UInt32,
        windowId: UInt64,
        eventType: MouseEventType,
        button: MouseButton? = nil,
        x: Double,
        y: Double,
        scrollDeltaX: Double = 0,
        scrollDeltaY: Double = 0,
        modifiers: KeyModifiers = []
    ) {
        self.messageId = messageId
        self.windowId = windowId
        self.eventType = eventType
        self.button = button
        self.x = x
        self.y = y
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.modifiers = modifiers
    }
}

/// Keyboard input event from host.
public struct KeyboardInputSpiceMessage: HostMessage {
    public let messageId: UInt32
    public let windowId: UInt64
    public let eventType: KeyEventType
    public let keyCode: UInt32
    public let scanCode: UInt32
    public let isExtendedKey: Bool
    public let modifiers: KeyModifiers
    public let character: String?

    public init(
        messageId: UInt32,
        windowId: UInt64,
        eventType: KeyEventType,
        keyCode: UInt32,
        scanCode: UInt32 = 0,
        isExtendedKey: Bool = false,
        modifiers: KeyModifiers = [],
        character: String? = nil
    ) {
        self.messageId = messageId
        self.windowId = windowId
        self.eventType = eventType
        self.keyCode = keyCode
        self.scanCode = scanCode
        self.isExtendedKey = isExtendedKey
        self.modifiers = modifiers
        self.character = character
    }
}

/// Drag and drop event from host.
public struct DragDropSpiceMessage: HostMessage {
    public let messageId: UInt32
    public let windowId: UInt64
    public let eventType: DragDropEventType
    public let x: Double
    public let y: Double
    public let files: [DraggedFile]
    public let allowedOperations: [DragOperation]
    public let selectedOperation: DragOperation?

    public init(
        messageId: UInt32,
        windowId: UInt64,
        eventType: DragDropEventType,
        x: Double,
        y: Double,
        files: [DraggedFile] = [],
        allowedOperations: [DragOperation] = [.copy],
        selectedOperation: DragOperation? = nil
    ) {
        self.messageId = messageId
        self.windowId = windowId
        self.eventType = eventType
        self.x = x
        self.y = y
        self.files = files
        self.allowedOperations = allowedOperations
        self.selectedOperation = selectedOperation
    }
}

/// Graceful shutdown request.
public struct ShutdownSpiceMessage: HostMessage {
    public let messageId: UInt32
    public let timeoutMs: Int32

    public init(messageId: UInt32, timeoutMs: Int32 = 5000) {
        self.messageId = messageId
        self.timeoutMs = timeoutMs
    }
}
