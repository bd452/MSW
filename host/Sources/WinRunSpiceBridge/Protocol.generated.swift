// Protocol.generated.swift
// AUTO-GENERATED FROM shared/protocol.def - DO NOT EDIT DIRECTLY
//
// To regenerate: make generate-protocol
// Source of truth: shared/protocol.def

import Foundation

// MARK: - Protocol Version

/// Protocol version constants - generated from shared/protocol.def
public enum SpiceProtocolVersion {
    public static let major: UInt16 = 1
    public static let minor: UInt16 = 0
    public static var combined: UInt32 {
        (UInt32(major) << 16) | UInt32(minor)
    }
}

// MARK: - Message Types

/// Message type codes - generated from shared/protocol.def
public enum SpiceMessageType: UInt8, CaseIterable, Codable, Sendable {
    // Host → Guest (0x00-0x7F)

    case launchProgram = 0x01
    case requestIcon = 0x02
    case clipboardData = 0x03
    case mouseInput = 0x04
    case keyboardInput = 0x05
    case dragDropEvent = 0x06
    case listSessions = 0x08
    case closeSession = 0x09
    case listShortcuts = 0x0A
    case shutdown = 0x0F

    // Guest → Host (0x80-0xFF)
    case windowMetadata = 0x80
    case frameData = 0x81
    case capabilityFlags = 0x82
    case dpiInfo = 0x83
    case iconData = 0x84
    case shortcutDetected = 0x85
    case clipboardChanged = 0x86
    case heartbeat = 0x87
    case telemetryReport = 0x88
    case provisionProgress = 0x89
    case provisionError = 0x8A
    case provisionComplete = 0x8B
    case sessionList = 0x8C
    case shortcutList = 0x8D
    case error = 0xFE
    case ack = 0xFF

    public var isHostToGuest: Bool { rawValue < 0x80 }
    public var isGuestToHost: Bool { rawValue >= 0x80 }
}

// MARK: - Guest Capabilities

/// Guest capability flags - generated from shared/protocol.def
public struct GuestCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let windowTracking = GuestCapabilities(rawValue: 0x01)
    public static let desktopDuplication = GuestCapabilities(rawValue: 0x02)
    public static let clipboardSync = GuestCapabilities(rawValue: 0x04)
    public static let dragDrop = GuestCapabilities(rawValue: 0x08)
    public static let iconExtraction = GuestCapabilities(rawValue: 0x10)
    public static let shortcutDetection = GuestCapabilities(rawValue: 0x20)
    public static let highDpiSupport = GuestCapabilities(rawValue: 0x40)
    public static let multiMonitor = GuestCapabilities(rawValue: 0x80)

    public static let allCore: GuestCapabilities = [
        .windowTracking, .desktopDuplication, .clipboardSync, .iconExtraction
    ]
}

// MARK: - Mouse Input

/// Mouse button codes - generated from shared/protocol.def
public enum MouseButton: UInt8, Codable, Sendable {

    case left = 1
    case right = 2
    case middle = 4
    case extra1 = 5
    case extra2 = 6
}

/// Mouse event types - generated from shared/protocol.def
public enum MouseEventType: UInt8, Codable, Sendable {

    case move = 0
    case press = 1
    case release = 2
    case scroll = 3
}

// MARK: - Keyboard Input

/// Key event types - generated from shared/protocol.def
public enum KeyEventType: UInt8, Codable, Sendable {

    case down = 0
    case up = 1
}

/// Key modifier flags - generated from shared/protocol.def
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 0x01)
    public static let control = KeyModifiers(rawValue: 0x02)
    public static let alt = KeyModifiers(rawValue: 0x04)
    public static let command = KeyModifiers(rawValue: 0x08)
    public static let capsLock = KeyModifiers(rawValue: 0x10)
    public static let numLock = KeyModifiers(rawValue: 0x20)
}

// MARK: - Drag and Drop

/// Drag/drop event types - generated from shared/protocol.def
public enum DragDropEventType: UInt8, Codable, Sendable {

    case enter = 0
    case move = 1
    case leave = 2
    case drop = 3
}

/// Drag operation types - generated from shared/protocol.def
public enum DragOperation: UInt8, Codable, Sendable {

    case none = 0
    case copy = 1
    case move = 2
    case link = 3
}

// MARK: - Pixel Formats

/// Pixel format types - generated from shared/protocol.def
public enum SpicePixelFormat: UInt8, Codable, Sendable {

    case bgra32 = 0
    case rgba32 = 1
}

// MARK: - Window Events

/// Window event types - generated from shared/protocol.def
public enum WindowEventType: Int32, Codable, Sendable {

    case created = 0
    case destroyed = 1
    case moved = 2
    case titleChanged = 3
    case focusChanged = 4
    case minimized = 5
    case restored = 6
    case updated = 7
}

// MARK: - Clipboard Formats

/// Clipboard format identifiers - generated from shared/protocol.def
public enum ClipboardFormat: String, Codable, CaseIterable, Sendable {

    case plainText
    case rtf
    case html
    case png
    case tiff
    case fileUrl
}

// MARK: - Provisioning Phases

/// Provisioning phase identifiers - generated from shared/protocol.def
public enum GuestProvisioningPhase: String, Codable, CaseIterable, Sendable {

    case drivers
    case agent
    case optimize
    case finalize
    case complete
}

// MARK: - Backwards Compatibility Typealiases
// These allow existing code referencing Generated* types to continue working
// TODO: Remove these after migrating all code to use the canonical type names

@available(*, deprecated, renamed: "SpiceProtocolVersion")
public typealias GeneratedProtocolVersion = SpiceProtocolVersion
@available(*, deprecated, renamed: "SpiceMessageType")
public typealias GeneratedMessageType = SpiceMessageType
@available(*, deprecated, renamed: "GuestCapabilities")
public typealias GeneratedCapabilities = GuestCapabilities
@available(*, deprecated, renamed: "MouseButton")
public typealias GeneratedMouseButton = MouseButton
@available(*, deprecated, renamed: "MouseEventType")
public typealias GeneratedMouseEventType = MouseEventType
@available(*, deprecated, renamed: "KeyEventType")
public typealias GeneratedKeyEventType = KeyEventType
@available(*, deprecated, renamed: "KeyModifiers")
public typealias GeneratedKeyModifiers = KeyModifiers
@available(*, deprecated, renamed: "DragDropEventType")
public typealias GeneratedDragDropEventType = DragDropEventType
@available(*, deprecated, renamed: "DragOperation")
public typealias GeneratedDragOperation = DragOperation
@available(*, deprecated, renamed: "SpicePixelFormat")
public typealias GeneratedPixelFormat = SpicePixelFormat
@available(*, deprecated, renamed: "WindowEventType")
public typealias GeneratedWindowEventType = WindowEventType
@available(*, deprecated, renamed: "ClipboardFormat")
public typealias GeneratedClipboardFormat = ClipboardFormat
@available(*, deprecated, renamed: "GuestProvisioningPhase")
public typealias GeneratedProvisioningPhase = GuestProvisioningPhase
