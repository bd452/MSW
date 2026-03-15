import Foundation

// MARK: - Key Code Mapping

/// Utility for converting macOS key codes to Windows virtual key codes
public struct KeyCodeMapper: Sendable {
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

    /// Determines whether the modifier key represented by macKeyCode is currently down.
    public static func isModifierKeyDown(macKeyCode: UInt16, flags: UInt) -> Bool {
        switch macKeyCode {
        case 0x38, 0x3C: return flags & (1 << 17) != 0 // shift
        case 0x3B, 0x3E: return flags & (1 << 18) != 0 // control
        case 0x3A, 0x3D: return flags & (1 << 19) != 0 // option/alt
        case 0x37, 0x36: return flags & (1 << 20) != 0 // command
        case 0x39: return flags & (1 << 16) != 0       // caps lock
        default: return false
        }
    }

    /// Convert a macOS virtual key code to PC Set 1 scan code used by Spice inputs.
    /// Returns 0 when unknown (caller may fallback to VK translation path).
    public static func windowsScanCode(fromMacOS macKeyCode: UInt16) -> UInt32 {
        macToScanCodeMap[macKeyCode] ?? 0
    }

    /// Whether the mapped PC scan code should be sent with E0 extended prefix.
    public static func isExtendedScanCode(fromMacOS macKeyCode: UInt16) -> Bool {
        extendedScanCodeKeys.contains(macKeyCode)
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

    // macOS keyCode -> PC Set 1 scancode (without E0 prefix).
    private static let macToScanCodeMap: [UInt16: UInt32] = [
        // Letters
        0x00: 0x1E, 0x01: 0x1F, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, 0x05: 0x22, 0x06: 0x2C,
        0x07: 0x2D, 0x08: 0x2E, 0x09: 0x2F, 0x0B: 0x30, 0x0C: 0x10, 0x0D: 0x11, 0x0E: 0x12,
        0x0F: 0x13, 0x10: 0x15, 0x11: 0x14, 0x1F: 0x18, 0x20: 0x16, 0x22: 0x17, 0x23: 0x19,
        0x25: 0x26, 0x26: 0x24, 0x28: 0x25, 0x2D: 0x31, 0x2E: 0x32,

        // Number row
        0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x17: 0x06,
        0x16: 0x07, 0x1A: 0x08, 0x1C: 0x09, 0x19: 0x0A, 0x1D: 0x0B,

        // Punctuation
        0x18: 0x0C, // =
        0x1B: 0x0D, // -
        0x21: 0x1A, // [
        0x1E: 0x1B, // ]
        0x2A: 0x2B, // \
        0x27: 0x27, // '
        0x29: 0x28, // ;
        0x2B: 0x33, // ,
        0x2C: 0x34, // /
        0x2F: 0x35, // .
        0x32: 0x29, // `

        // Control keys
        0x24: 0x1C, // Return
        0x30: 0x0F, // Tab
        0x31: 0x39, // Space
        0x33: 0x0E, // Backspace
        0x35: 0x01, // Escape
        0x75: 0x53, // Forward delete (extended)
        0x73: 0x47, // Home (extended)
        0x77: 0x4F, // End (extended)
        0x74: 0x49, // Page Up (extended)
        0x79: 0x51, // Page Down (extended)

        // Arrows (all extended)
        0x7B: 0x4B, // Left
        0x7C: 0x4D, // Right
        0x7D: 0x50, // Down
        0x7E: 0x48, // Up

        // Function keys
        0x7A: 0x3B, 0x78: 0x3C, 0x63: 0x3D, 0x76: 0x3E, 0x60: 0x3F, 0x61: 0x40,
        0x62: 0x41, 0x64: 0x42, 0x65: 0x43, 0x6D: 0x44, 0x67: 0x57, 0x6F: 0x58,

        // Modifiers
        0x38: 0x2A, // Left Shift
        0x3C: 0x36, // Right Shift
        0x3B: 0x1D, // Left Control
        0x3E: 0x1D, // Right Control (extended)
        0x3A: 0x38, // Left Alt
        0x3D: 0x38, // Right Alt (extended)
        0x37: 0x5B, // Left Command (LWIN, extended)
        0x36: 0x5C, // Right Command (RWIN, extended)
        0x39: 0x3A, // Caps Lock
    ]

    private static let extendedScanCodeKeys: Set<UInt16> = [
        0x75, 0x73, 0x77, 0x74, 0x79, // Del/Home/End/PgUp/PgDn
        0x7B, 0x7C, 0x7D, 0x7E,       // arrows
        0x3E, 0x3D,                   // right ctrl/alt
        0x37, 0x36,                   // cmd -> win
    ]
}
