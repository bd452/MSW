// Protocol.generated.swift
// AUTO-GENERATED FROM shared/protocol.def - DO NOT EDIT DIRECTLY
//
// To regenerate: make generate-protocol
// Source of truth: shared/protocol.def

import Foundation

// MARK: - Protocol Version

/// Protocol version constants - generated from shared/protocol.def
public enum GeneratedProtocolVersion {
    public static let major: UInt16 = 1
    public static let minor: UInt16 = 0
    public static var combined: UInt32 {
        (UInt32(major) << 16) | UInt32(minor)
    }
}

// MARK: - Message Types

/// Message type codes - generated from shared/protocol.def
public enum GeneratedMessageType: UInt8, CaseIterable {
    // Host → Guest (0x00-0x7F)
    case launchProgram = 0x01
    case requestIcon = 0x02
    case clipboardData = 0x03
    case mouseInput = 0x04
    case keyboardInput = 0x05
    case dragDropEvent = 0x06
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
    case error = 0xFE
    case ack = 0xFF

    public var isHostToGuest: Bool { rawValue < 0x80 }
    public var isGuestToHost: Bool { rawValue >= 0x80 }
}

// MARK: - Guest Capabilities

/// Guest capability flags - generated from shared/protocol.def
public struct GeneratedCapabilities: OptionSet, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let windowTracking = GeneratedCapabilities(rawValue: 0x01)
    public static let desktopDuplication = GeneratedCapabilities(rawValue: 0x02)
    public static let clipboardSync = GeneratedCapabilities(rawValue: 0x04)
    public static let dragDrop = GeneratedCapabilities(rawValue: 0x08)
    public static let iconExtraction = GeneratedCapabilities(rawValue: 0x10)
    public static let shortcutDetection = GeneratedCapabilities(rawValue: 0x20)
    public static let highDpiSupport = GeneratedCapabilities(rawValue: 0x40)
    public static let multiMonitor = GeneratedCapabilities(rawValue: 0x80)

    public static let allCore: GeneratedCapabilities = [
        .windowTracking, .desktopDuplication, .clipboardSync, .iconExtraction
    ]
}

// MARK: - Mouse Input

/// Mouse button codes - generated from shared/protocol.def
public enum GeneratedMouseButton: UInt8, Codable {
    case left = 1
    case right = 2
    case middle = 4
    case extra1 = 5
    case extra2 = 6
}

/// Mouse event types - generated from shared/protocol.def
public enum GeneratedMouseEventType: UInt8, Codable {
    case move = 0
    case press = 1
    case release = 2
    case scroll = 3
}

// MARK: - Keyboard Input

/// Key event types - generated from shared/protocol.def
public enum GeneratedKeyEventType: UInt8, Codable {
    case down = 0
    case up = 1
}

/// Key modifier flags - generated from shared/protocol.def
public struct GeneratedKeyModifiers: OptionSet, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = GeneratedKeyModifiers(rawValue: 0x01)
    public static let control = GeneratedKeyModifiers(rawValue: 0x02)
    public static let alt = GeneratedKeyModifiers(rawValue: 0x04)
    public static let command = GeneratedKeyModifiers(rawValue: 0x08)
    public static let capsLock = GeneratedKeyModifiers(rawValue: 0x10)
    public static let numLock = GeneratedKeyModifiers(rawValue: 0x20)
}

// MARK: - Drag and Drop

/// Drag/drop event types - generated from shared/protocol.def
public enum GeneratedDragDropEventType: UInt8, Codable {
    case enter = 0
    case move = 1
    case leave = 2
    case drop = 3
}

/// Drag operation types - generated from shared/protocol.def
public enum GeneratedDragOperation: UInt8, Codable {
    case none = 0
    case copy = 1
    case move = 2
    case link = 3
}

// MARK: - Pixel Formats

/// Pixel format types - generated from shared/protocol.def
public enum GeneratedPixelFormat: UInt8, Codable {
    case bgra32 = 0
    case rgba32 = 1
}

// MARK: - Window Events

/// Window event types - generated from shared/protocol.def
public enum GeneratedWindowEventType: Int32, Codable {
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
public enum GeneratedClipboardFormat: String, Codable, CaseIterable {
    case plainText = "PlainText"
    case rtf = "Rtf"
    case html = "Html"
    case png = "Png"
    case tiff = "Tiff"
    case fileUrl = "FileUrl"
}

// MARK: - Provisioning Phases

/// Provisioning phase identifiers - generated from shared/protocol.def
public enum GeneratedProvisioningPhase: String, Codable, CaseIterable {
    case drivers = "Drivers"
    case agent = "Agent"
    case optimize = "Optimize"
    case finalize = "Finalize"
    case complete = "Complete"
}
