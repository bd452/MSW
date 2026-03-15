import Testing
@testable import WinRunSpiceBridge

@Suite("KeyCodeMapper")
struct KeyCodeMapperTests {
    // MARK: - Command ↔ Control Swap

    @Test("macOS Command modifier maps to guest Control")
    func commandMapsToControl() {
        let commandFlag: UInt = 1 << 20
        let mods = KeyCodeMapper.modifiers(fromMacOS: commandFlag)
        #expect(mods.contains(.control))
        #expect(!mods.contains(.command))
    }

    @Test("macOS Control modifier maps to guest Command/Win")
    func controlMapsToCommand() {
        let controlFlag: UInt = 1 << 18
        let mods = KeyCodeMapper.modifiers(fromMacOS: controlFlag)
        #expect(mods.contains(.command))
        #expect(!mods.contains(.control))
    }

    @Test("Left Command key produces VK_CONTROL")
    func leftCommandKeyCode() {
        let vk = KeyCodeMapper.windowsKeyCode(fromMacOS: 0x37)
        #expect(vk == 0x11) // VK_CONTROL
    }

    @Test("Left Control key produces VK_LWIN")
    func leftControlKeyCode() {
        let vk = KeyCodeMapper.windowsKeyCode(fromMacOS: 0x3B)
        #expect(vk == 0x5B) // VK_LWIN
    }

    @Test("Right Command key produces VK_CONTROL")
    func rightCommandKeyCode() {
        let vk = KeyCodeMapper.windowsKeyCode(fromMacOS: 0x36)
        #expect(vk == 0x11) // VK_CONTROL
    }

    @Test("Right Control key produces VK_RWIN")
    func rightControlKeyCode() {
        let vk = KeyCodeMapper.windowsKeyCode(fromMacOS: 0x3E)
        #expect(vk == 0x5C) // VK_RWIN
    }

    // MARK: - Scan Codes

    @Test("Left Command scan code is Left Ctrl (0x1D, not extended)")
    func leftCommandScanCode() {
        let scan = KeyCodeMapper.windowsScanCode(fromMacOS: 0x37)
        #expect(scan == 0x1D)
        #expect(!KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x37))
    }

    @Test("Right Command scan code is Right Ctrl (0x1D, extended)")
    func rightCommandScanCode() {
        let scan = KeyCodeMapper.windowsScanCode(fromMacOS: 0x36)
        #expect(scan == 0x1D)
        #expect(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x36))
    }

    @Test("Left Control scan code is Left Win (0x5B, extended)")
    func leftControlScanCode() {
        let scan = KeyCodeMapper.windowsScanCode(fromMacOS: 0x3B)
        #expect(scan == 0x5B)
        #expect(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x3B))
    }

    // MARK: - Modifier Key Down Detection

    @Test("isModifierKeyDown detects Command key from command flag")
    func commandKeyDownDetection() {
        let commandFlag: UInt = 1 << 20
        #expect(KeyCodeMapper.isModifierKeyDown(macKeyCode: 0x37, flags: commandFlag))
        #expect(!KeyCodeMapper.isModifierKeyDown(macKeyCode: 0x37, flags: 0))
    }

    @Test("isModifierKeyDown detects Control key from control flag")
    func controlKeyDownDetection() {
        let controlFlag: UInt = 1 << 18
        #expect(KeyCodeMapper.isModifierKeyDown(macKeyCode: 0x3B, flags: controlFlag))
        #expect(!KeyCodeMapper.isModifierKeyDown(macKeyCode: 0x3B, flags: 0))
    }

    // MARK: - Standard Key Mappings

    @Test("Letter keys map correctly")
    func letterKeys() {
        #expect(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x00) == 0x41) // A
        #expect(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x08) == 0x43) // C
        #expect(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x09) == 0x56) // V
    }

    @Test("Arrow keys have extended scan codes")
    func arrowKeysExtended() {
        #expect(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x7B)) // Left
        #expect(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x7C)) // Right
        #expect(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x7D)) // Down
        #expect(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x7E)) // Up
    }

    @Test("Right-side modifier VK codes are mapped")
    func rightSideModifierVKCodes() {
        #expect(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x3C) == 0x10) // Right Shift
        #expect(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x3D) == 0x12) // Right Option/Alt
    }

    @Test("Combined modifiers map correctly with swap")
    func combinedModifiers() {
        let cmdShift: UInt = (1 << 20) | (1 << 17)
        let mods = KeyCodeMapper.modifiers(fromMacOS: cmdShift)
        #expect(mods.contains(.control))
        #expect(mods.contains(.shift))
        #expect(!mods.contains(.command))
    }
}
