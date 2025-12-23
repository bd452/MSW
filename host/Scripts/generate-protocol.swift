#!/usr/bin/env swift
// generate-protocol.swift
// Generates Protocol.generated.swift from shared/protocol.def
//
// Usage: swift generate-protocol.swift [path/to/protocol.def] [output/path.swift]

import Foundation

// MARK: - Parser

struct ProtocolDefinition {
    var version: (major: Int, minor: Int) = (1, 0)
    var messageTypesHostToGuest: [(name: String, value: Int)] = []
    var messageTypesGuestToHost: [(name: String, value: Int)] = []
    var capabilities: [(name: String, value: Int)] = []
    var mouseButtons: [(name: String, value: Int)] = []
    var mouseEventTypes: [(name: String, value: Int)] = []
    var keyEventTypes: [(name: String, value: Int)] = []
    var keyModifiers: [(name: String, value: Int)] = []
    var dragDropEventTypes: [(name: String, value: Int)] = []
    var dragOperations: [(name: String, value: Int)] = []
    var pixelFormats: [(name: String, value: Int)] = []
    var windowEventTypes: [(name: String, value: Int)] = []
    var clipboardFormats: [(name: String, value: String)] = []
    var provisioningPhases: [(name: String, value: String)] = []
}

func parseValue(_ str: String) -> Int {
    let trimmed = str.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
        return Int(trimmed.dropFirst(2), radix: 16) ?? 0
    }
    return Int(trimmed) ?? 0
}

func parseProtocolDef(at path: String) throws -> ProtocolDefinition {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    var def = ProtocolDefinition()
    var currentSection = ""
    
    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Skip comments and empty lines
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            continue
        }
        
        // Section header
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            currentSection = String(trimmed.dropFirst().dropLast())
            continue
        }
        
        // Key = Value
        let parts = trimmed.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        
        switch currentSection {
        case "VERSION":
            if key == "PROTOCOL_VERSION_MAJOR" {
                def.version.major = parseValue(value)
            } else if key == "PROTOCOL_VERSION_MINOR" {
                def.version.minor = parseValue(value)
            }
            
        case "MESSAGE_TYPES_HOST_TO_GUEST":
            def.messageTypesHostToGuest.append((key, parseValue(value)))
            
        case "MESSAGE_TYPES_GUEST_TO_HOST":
            def.messageTypesGuestToHost.append((key, parseValue(value)))
            
        case "CAPABILITIES":
            def.capabilities.append((key, parseValue(value)))
            
        case "MOUSE_BUTTONS":
            def.mouseButtons.append((key, parseValue(value)))
            
        case "MOUSE_EVENT_TYPES":
            def.mouseEventTypes.append((key, parseValue(value)))
            
        case "KEY_EVENT_TYPES":
            def.keyEventTypes.append((key, parseValue(value)))
            
        case "KEY_MODIFIERS":
            def.keyModifiers.append((key, parseValue(value)))
            
        case "DRAG_DROP_EVENT_TYPES":
            def.dragDropEventTypes.append((key, parseValue(value)))
            
        case "DRAG_OPERATIONS":
            def.dragOperations.append((key, parseValue(value)))
            
        case "PIXEL_FORMATS":
            def.pixelFormats.append((key, parseValue(value)))
            
        case "WINDOW_EVENT_TYPES":
            def.windowEventTypes.append((key, parseValue(value)))
            
        case "CLIPBOARD_FORMATS":
            def.clipboardFormats.append((key, value))
            
        case "PROVISIONING_PHASES":
            def.provisioningPhases.append((key, value))
            
        default:
            break
        }
    }
    
    return def
}

// MARK: - Code Generation

func toSwiftEnumCase(_ name: String, prefix: String) -> String {
    // Convert MSG_LAUNCH_PROGRAM -> launchProgram
    var result = name
    if result.hasPrefix(prefix) {
        result = String(result.dropFirst(prefix.count))
    }
    // Convert SNAKE_CASE to camelCase
    let parts = result.lowercased().split(separator: "_")
    if parts.isEmpty { return result.lowercased() }
    return parts[0] + parts.dropFirst().map { $0.capitalized }.joined()
}

func toHex(_ value: Int, minWidth: Int = 2) -> String {
    // Format as uppercase hex with minimum width (zero-padded)
    let hex = String(value, radix: 16, uppercase: true)
    if hex.count < minWidth {
        return String(repeating: "0", count: minWidth - hex.count) + hex
    }
    return hex
}

func generateSwift(_ def: ProtocolDefinition) -> String {
    var out = """
    // Protocol.generated.swift
    // AUTO-GENERATED FROM shared/protocol.def - DO NOT EDIT DIRECTLY
    //
    // To regenerate: make generate-protocol
    // Source of truth: shared/protocol.def
    
    import Foundation
    
    // MARK: - Protocol Version
    
    /// Protocol version constants - generated from shared/protocol.def
    public enum GeneratedProtocolVersion {
        public static let major: UInt16 = \(def.version.major)
        public static let minor: UInt16 = \(def.version.minor)
        public static var combined: UInt32 {
            (UInt32(major) << 16) | UInt32(minor)
        }
    }
    
    // MARK: - Message Types
    
    /// Message type codes - generated from shared/protocol.def
    public enum GeneratedMessageType: UInt8, CaseIterable {
        // Host → Guest (0x00-0x7F)
    
    """
    
    for (name, value) in def.messageTypesHostToGuest {
        let caseName = toSwiftEnumCase(name, prefix: "MSG_")
        out += "    case \(caseName) = 0x\(toHex(value))\n"
    }
    
    out += "\n    // Guest → Host (0x80-0xFF)\n"
    
    for (name, value) in def.messageTypesGuestToHost {
        let caseName = toSwiftEnumCase(name, prefix: "MSG_")
        out += "    case \(caseName) = 0x\(toHex(value))\n"
    }
    
    out += """
    
        public var isHostToGuest: Bool { rawValue < 0x80 }
        public var isGuestToHost: Bool { rawValue >= 0x80 }
    }
    
    // MARK: - Guest Capabilities
    
    /// Guest capability flags - generated from shared/protocol.def
    public struct GeneratedCapabilities: OptionSet, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
    
    
    """
    
    for (name, value) in def.capabilities {
        let caseName = toSwiftEnumCase(name, prefix: "CAP_")
        out += "    public static let \(caseName) = GeneratedCapabilities(rawValue: 0x\(toHex(value)))\n"
    }
    
    out += """
    
        public static let allCore: GeneratedCapabilities = [
            .windowTracking, .desktopDuplication, .clipboardSync, .iconExtraction
        ]
    }
    
    // MARK: - Mouse Input
    
    /// Mouse button codes - generated from shared/protocol.def
    public enum GeneratedMouseButton: UInt8, Codable {
    
    """
    
    for (name, value) in def.mouseButtons {
        let caseName = toSwiftEnumCase(name, prefix: "MOUSE_BUTTON_")
        out += "    case \(caseName) = \(value)\n"
    }
    
    out += """
    }
    
    /// Mouse event types - generated from shared/protocol.def
    public enum GeneratedMouseEventType: UInt8, Codable {
    
    """
    
    for (name, value) in def.mouseEventTypes {
        let caseName = toSwiftEnumCase(name, prefix: "MOUSE_EVENT_")
        out += "    case \(caseName) = \(value)\n"
    }
    
    out += """
    }
    
    // MARK: - Keyboard Input
    
    /// Key event types - generated from shared/protocol.def
    public enum GeneratedKeyEventType: UInt8, Codable {
    
    """
    
    for (name, value) in def.keyEventTypes {
        let caseName = toSwiftEnumCase(name, prefix: "KEY_EVENT_")
        out += "    case \(caseName) = \(value)\n"
    }
    
    out += """
    }
    
    /// Key modifier flags - generated from shared/protocol.def
    public struct GeneratedKeyModifiers: OptionSet, Codable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
    
    
    """
    
    for (name, value) in def.keyModifiers where name != "KEY_MOD_NONE" {
        let caseName = toSwiftEnumCase(name, prefix: "KEY_MOD_")
        out += "    public static let \(caseName) = GeneratedKeyModifiers(rawValue: 0x\(toHex(value)))\n"
    }
    
    out += """
    }
    
    // MARK: - Drag and Drop
    
    /// Drag/drop event types - generated from shared/protocol.def
    public enum GeneratedDragDropEventType: UInt8, Codable {
    
    """
    
    for (name, value) in def.dragDropEventTypes {
        let caseName = toSwiftEnumCase(name, prefix: "DRAG_EVENT_")
        out += "    case \(caseName) = \(value)\n"
    }
    
    out += """
    }
    
    /// Drag operation types - generated from shared/protocol.def
    public enum GeneratedDragOperation: UInt8, Codable {
    
    """
    
    for (name, value) in def.dragOperations {
        let caseName = toSwiftEnumCase(name, prefix: "DRAG_OP_")
        out += "    case \(caseName) = \(value)\n"
    }
    
    out += """
    }
    
    // MARK: - Pixel Formats
    
    /// Pixel format types - generated from shared/protocol.def
    public enum GeneratedPixelFormat: UInt8, Codable {
    
    """
    
    for (name, value) in def.pixelFormats {
        let caseName = toSwiftEnumCase(name, prefix: "PIXEL_FORMAT_")
        out += "    case \(caseName) = \(value)\n"
    }
    
    out += """
    }
    
    // MARK: - Window Events
    
    /// Window event types - generated from shared/protocol.def
    public enum GeneratedWindowEventType: Int32, Codable {
    
    """
    
    for (name, value) in def.windowEventTypes {
        let caseName = toSwiftEnumCase(name, prefix: "WINDOW_EVENT_")
        out += "    case \(caseName) = \(value)\n"
    }
    
    out += """
    }
    
    // MARK: - Clipboard Formats
    
    /// Clipboard format identifiers - generated from shared/protocol.def
    public enum GeneratedClipboardFormat: String, Codable, CaseIterable {
    
    """
    
    for (name, value) in def.clipboardFormats {
        let caseName = toSwiftEnumCase(name, prefix: "CLIPBOARD_FORMAT_")
        out += "    case \(caseName) = \"\(value)\"\n"
    }
    
    out += """
    }
    
    // MARK: - Provisioning Phases
    
    /// Provisioning phase identifiers - generated from shared/protocol.def
    public enum GeneratedProvisioningPhase: String, Codable, CaseIterable {
    
    """
    
    for (name, value) in def.provisioningPhases {
        let caseName = toSwiftEnumCase(name, prefix: "PROVISION_PHASE_")
        out += "    case \(caseName) = \"\(value)\"\n"
    }
    
    out += "}\n"
    
    return out
}

// MARK: - Main

let args = CommandLine.arguments
let scriptDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent().deletingLastPathComponent()

let inputPath = args.count > 1 
    ? args[1] 
    : repoRoot.appendingPathComponent("shared/protocol.def").path

let outputPath = args.count > 2 
    ? args[2] 
    : repoRoot.appendingPathComponent("host/Sources/WinRunSpiceBridge/Protocol.generated.swift").path

do {
    let def = try parseProtocolDef(at: inputPath)
    let swift = generateSwift(def)
    try swift.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("✅ Generated \(outputPath)")
} catch {
    fputs("❌ Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
