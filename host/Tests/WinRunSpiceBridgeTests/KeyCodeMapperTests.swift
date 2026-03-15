import XCTest
@testable import WinRunSpiceBridge

final class KeyCodeMapperTests: XCTestCase {
    // MARK: - Command ↔ Control Swap

    func testCommandMapsToControl() {
        let commandFlag: UInt = 1 << 20
        let mods = KeyCodeMapper.modifiers(fromMacOS: commandFlag)
        XCTAssertTrue(mods.contains(.control))
        XCTAssertFalse(mods.contains(.command))
    }

    func testControlMapsToCommand() {
        let controlFlag: UInt = 1 << 18
        let mods = KeyCodeMapper.modifiers(fromMacOS: controlFlag)
        XCTAssertTrue(mods.contains(.command))
        XCTAssertFalse(mods.contains(.control))
    }

    func testLeftCommandKeyCode() {
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x37), 0x11) // VK_CONTROL
    }

    func testLeftControlKeyCode() {
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x3B), 0x5B) // VK_LWIN
    }

    func testRightCommandKeyCode() {
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x36), 0x11) // VK_CONTROL
    }

    func testRightControlKeyCode() {
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x3E), 0x5C) // VK_RWIN
    }

    // MARK: - Scan Codes

    func testLeftCommandScanCode() {
        XCTAssertEqual(KeyCodeMapper.windowsScanCode(fromMacOS: 0x37), 0x1D)
        XCTAssertFalse(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x37))
    }

    func testRightCommandScanCode() {
        XCTAssertEqual(KeyCodeMapper.windowsScanCode(fromMacOS: 0x36), 0x1D)
        XCTAssertTrue(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x36))
    }

    func testLeftControlScanCode() {
        XCTAssertEqual(KeyCodeMapper.windowsScanCode(fromMacOS: 0x3B), 0x5B)
        XCTAssertTrue(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x3B))
    }

    // MARK: - Modifier Key Down Detection

    func testCommandKeyDownDetection() {
        let commandFlag: UInt = 1 << 20
        XCTAssertTrue(KeyCodeMapper.isModifierKeyDown(macKeyCode: 0x37, flags: commandFlag))
        XCTAssertFalse(KeyCodeMapper.isModifierKeyDown(macKeyCode: 0x37, flags: 0))
    }

    func testControlKeyDownDetection() {
        let controlFlag: UInt = 1 << 18
        XCTAssertTrue(KeyCodeMapper.isModifierKeyDown(macKeyCode: 0x3B, flags: controlFlag))
        XCTAssertFalse(KeyCodeMapper.isModifierKeyDown(macKeyCode: 0x3B, flags: 0))
    }

    // MARK: - Standard Key Mappings

    func testLetterKeys() {
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x00), 0x41) // A
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x08), 0x43) // C
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x09), 0x56) // V
    }

    func testArrowKeysExtended() {
        XCTAssertTrue(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x7B))  // Left
        XCTAssertTrue(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x7C))  // Right
        XCTAssertTrue(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x7D))  // Down
        XCTAssertTrue(KeyCodeMapper.isExtendedScanCode(fromMacOS: 0x7E))  // Up
    }

    func testRightSideModifierVKCodes() {
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x3C), 0x10) // Right Shift
        XCTAssertEqual(KeyCodeMapper.windowsKeyCode(fromMacOS: 0x3D), 0x12) // Right Option/Alt
    }

    func testCombinedModifiers() {
        let cmdShift: UInt = (1 << 20) | (1 << 17)
        let mods = KeyCodeMapper.modifiers(fromMacOS: cmdShift)
        XCTAssertTrue(mods.contains(.control))
        XCTAssertTrue(mods.contains(.shift))
        XCTAssertFalse(mods.contains(.command))
    }
}
