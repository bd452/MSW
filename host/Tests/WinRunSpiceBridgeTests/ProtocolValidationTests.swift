import XCTest

@testable import WinRunSpiceBridge

/// Tests that validate protocol constants match expected values from shared/protocol.def.
/// These tests ensure the generated types have correct values.
final class ProtocolValidationTests: XCTestCase {
    // MARK: - Protocol Version

    func testProtocolVersionValues() {
        // From protocol.def: PROTOCOL_VERSION_MAJOR = 1, PROTOCOL_VERSION_MINOR = 0
        XCTAssertEqual(SpiceProtocolVersion.major, 1)
        XCTAssertEqual(SpiceProtocolVersion.minor, 0)
        XCTAssertEqual(SpiceProtocolVersion.combined, 0x0001_0000)
    }

    // MARK: - Message Types (Host → Guest)

    func testHostToGuestMessageTypeValues() {
        // From protocol.def [MESSAGE_TYPES_HOST_TO_GUEST]
        XCTAssertEqual(SpiceMessageType.launchProgram.rawValue, 0x01)
        XCTAssertEqual(SpiceMessageType.requestIcon.rawValue, 0x02)
        XCTAssertEqual(SpiceMessageType.clipboardData.rawValue, 0x03)
        XCTAssertEqual(SpiceMessageType.mouseInput.rawValue, 0x04)
        XCTAssertEqual(SpiceMessageType.keyboardInput.rawValue, 0x05)
        XCTAssertEqual(SpiceMessageType.dragDropEvent.rawValue, 0x06)
        XCTAssertEqual(SpiceMessageType.listSessions.rawValue, 0x08)
        XCTAssertEqual(SpiceMessageType.closeSession.rawValue, 0x09)
        XCTAssertEqual(SpiceMessageType.listShortcuts.rawValue, 0x0A)
        XCTAssertEqual(SpiceMessageType.shutdown.rawValue, 0x0F)
    }

    func testHostToGuestMessagesAreInCorrectRange() {
        // Host → Guest messages should be in range 0x00-0x7F
        let hostMessages: [SpiceMessageType] = [
            .launchProgram, .requestIcon, .clipboardData, .mouseInput,
            .keyboardInput, .dragDropEvent, .listSessions, .closeSession,
            .listShortcuts, .shutdown,
        ]
        for msg in hostMessages {
            XCTAssertTrue(msg.isHostToGuest, "\(msg) should be host→guest")
            XCTAssertFalse(msg.isGuestToHost, "\(msg) should not be guest→host")
            XCTAssertLessThan(msg.rawValue, 0x80, "\(msg) should be < 0x80")
        }
    }

    // MARK: - Message Types (Guest → Host)

    func testGuestToHostMessageTypeValues() {
        // From protocol.def [MESSAGE_TYPES_GUEST_TO_HOST]
        XCTAssertEqual(SpiceMessageType.windowMetadata.rawValue, 0x80)
        XCTAssertEqual(SpiceMessageType.frameData.rawValue, 0x81)
        XCTAssertEqual(SpiceMessageType.capabilityFlags.rawValue, 0x82)
        XCTAssertEqual(SpiceMessageType.dpiInfo.rawValue, 0x83)
        XCTAssertEqual(SpiceMessageType.iconData.rawValue, 0x84)
        XCTAssertEqual(SpiceMessageType.shortcutDetected.rawValue, 0x85)
        XCTAssertEqual(SpiceMessageType.clipboardChanged.rawValue, 0x86)
        XCTAssertEqual(SpiceMessageType.heartbeat.rawValue, 0x87)
        XCTAssertEqual(SpiceMessageType.telemetryReport.rawValue, 0x88)
        XCTAssertEqual(SpiceMessageType.provisionProgress.rawValue, 0x89)
        XCTAssertEqual(SpiceMessageType.provisionError.rawValue, 0x8A)
        XCTAssertEqual(SpiceMessageType.provisionComplete.rawValue, 0x8B)
        XCTAssertEqual(SpiceMessageType.sessionList.rawValue, 0x8C)
        XCTAssertEqual(SpiceMessageType.shortcutList.rawValue, 0x8D)
        XCTAssertEqual(SpiceMessageType.error.rawValue, 0xFE)
        XCTAssertEqual(SpiceMessageType.ack.rawValue, 0xFF)
    }

    func testGuestToHostMessagesAreInCorrectRange() {
        // Guest → Host messages should be in range 0x80-0xFF
        let guestMessages: [SpiceMessageType] = [
            .windowMetadata, .frameData, .capabilityFlags, .dpiInfo,
            .iconData, .shortcutDetected, .clipboardChanged, .heartbeat,
            .telemetryReport, .provisionProgress, .provisionError,
            .provisionComplete, .sessionList, .shortcutList, .error, .ack,
        ]
        for msg in guestMessages {
            XCTAssertTrue(msg.isGuestToHost, "\(msg) should be guest→host")
            XCTAssertFalse(msg.isHostToGuest, "\(msg) should not be host→guest")
            XCTAssertGreaterThanOrEqual(msg.rawValue, 0x80, "\(msg) should be >= 0x80")
        }
    }

    // MARK: - Guest Capabilities

    func testCapabilityValues() {
        // From protocol.def [CAPABILITIES]
        XCTAssertEqual(GuestCapabilities.windowTracking.rawValue, 0x01)
        XCTAssertEqual(GuestCapabilities.desktopDuplication.rawValue, 0x02)
        XCTAssertEqual(GuestCapabilities.clipboardSync.rawValue, 0x04)
        XCTAssertEqual(GuestCapabilities.dragDrop.rawValue, 0x08)
        XCTAssertEqual(GuestCapabilities.iconExtraction.rawValue, 0x10)
        XCTAssertEqual(GuestCapabilities.shortcutDetection.rawValue, 0x20)
        XCTAssertEqual(GuestCapabilities.highDpiSupport.rawValue, 0x40)
        XCTAssertEqual(GuestCapabilities.multiMonitor.rawValue, 0x80)
    }

    func testAllCoreCapabilities() {
        // allCore should include the essential capabilities
        let allCore = GuestCapabilities.allCore
        XCTAssertTrue(allCore.contains(.windowTracking))
        XCTAssertTrue(allCore.contains(.desktopDuplication))
        XCTAssertTrue(allCore.contains(.clipboardSync))
        XCTAssertTrue(allCore.contains(.iconExtraction))
    }

    // MARK: - Mouse Input

    func testMouseButtonValues() {
        // From protocol.def [MOUSE_BUTTONS]
        XCTAssertEqual(MouseButton.left.rawValue, 1)
        XCTAssertEqual(MouseButton.right.rawValue, 2)
        XCTAssertEqual(MouseButton.middle.rawValue, 4)
        XCTAssertEqual(MouseButton.extra1.rawValue, 5)
        XCTAssertEqual(MouseButton.extra2.rawValue, 6)
    }

    func testMouseEventTypeValues() {
        // From protocol.def [MOUSE_EVENT_TYPES]
        XCTAssertEqual(MouseEventType.move.rawValue, 0)
        XCTAssertEqual(MouseEventType.press.rawValue, 1)
        XCTAssertEqual(MouseEventType.release.rawValue, 2)
        XCTAssertEqual(MouseEventType.scroll.rawValue, 3)
    }

    // MARK: - Keyboard Input

    func testKeyEventTypeValues() {
        // From protocol.def [KEY_EVENT_TYPES]
        XCTAssertEqual(KeyEventType.down.rawValue, 0)
        XCTAssertEqual(KeyEventType.up.rawValue, 1)
    }

    func testKeyModifierValues() {
        // From protocol.def [KEY_MODIFIERS]
        XCTAssertEqual(KeyModifiers.shift.rawValue, 0x01)
        XCTAssertEqual(KeyModifiers.control.rawValue, 0x02)
        XCTAssertEqual(KeyModifiers.alt.rawValue, 0x04)
        XCTAssertEqual(KeyModifiers.command.rawValue, 0x08)
        XCTAssertEqual(KeyModifiers.capsLock.rawValue, 0x10)
        XCTAssertEqual(KeyModifiers.numLock.rawValue, 0x20)
    }

    // MARK: - Drag and Drop

    func testDragDropEventTypeValues() {
        // From protocol.def [DRAG_DROP_EVENT_TYPES]
        XCTAssertEqual(DragDropEventType.enter.rawValue, 0)
        XCTAssertEqual(DragDropEventType.move.rawValue, 1)
        XCTAssertEqual(DragDropEventType.leave.rawValue, 2)
        XCTAssertEqual(DragDropEventType.drop.rawValue, 3)
    }

    func testDragOperationValues() {
        // From protocol.def [DRAG_OPERATIONS]
        XCTAssertEqual(DragOperation.none.rawValue, 0)
        XCTAssertEqual(DragOperation.copy.rawValue, 1)
        XCTAssertEqual(DragOperation.move.rawValue, 2)
        XCTAssertEqual(DragOperation.link.rawValue, 3)
    }

    // MARK: - Pixel Formats

    func testPixelFormatValues() {
        // From protocol.def [PIXEL_FORMATS]
        XCTAssertEqual(SpicePixelFormat.bgra32.rawValue, 0)
        XCTAssertEqual(SpicePixelFormat.rgba32.rawValue, 1)
    }

    // MARK: - Window Events

    func testWindowEventTypeValues() {
        // From protocol.def [WINDOW_EVENT_TYPES]
        XCTAssertEqual(WindowEventType.created.rawValue, 0)
        XCTAssertEqual(WindowEventType.destroyed.rawValue, 1)
        XCTAssertEqual(WindowEventType.moved.rawValue, 2)
        XCTAssertEqual(WindowEventType.titleChanged.rawValue, 3)
        XCTAssertEqual(WindowEventType.focusChanged.rawValue, 4)
        XCTAssertEqual(WindowEventType.minimized.rawValue, 5)
        XCTAssertEqual(WindowEventType.restored.rawValue, 6)
        XCTAssertEqual(WindowEventType.updated.rawValue, 7)
    }

    // MARK: - Clipboard Formats

    func testClipboardFormatValues() {
        // From protocol.def [CLIPBOARD_FORMATS]
        XCTAssertEqual(ClipboardFormat.plainText.rawValue, "plainText")
        XCTAssertEqual(ClipboardFormat.rtf.rawValue, "rtf")
        XCTAssertEqual(ClipboardFormat.html.rawValue, "html")
        XCTAssertEqual(ClipboardFormat.png.rawValue, "png")
        XCTAssertEqual(ClipboardFormat.tiff.rawValue, "tiff")
        XCTAssertEqual(ClipboardFormat.fileUrl.rawValue, "fileUrl")
    }

    // MARK: - Provisioning Phases

    func testProvisioningPhaseValues() {
        // From protocol.def [PROVISIONING_PHASES]
        XCTAssertEqual(GuestProvisioningPhase.drivers.rawValue, "drivers")
        XCTAssertEqual(GuestProvisioningPhase.agent.rawValue, "agent")
        XCTAssertEqual(GuestProvisioningPhase.optimize.rawValue, "optimize")
        XCTAssertEqual(GuestProvisioningPhase.finalize.rawValue, "finalize")
        XCTAssertEqual(GuestProvisioningPhase.complete.rawValue, "complete")
    }

    // MARK: - Completeness

    func testAllMessageTypesAreCovered() {
        // Ensure we haven't added message types without adding tests
        let allCases = SpiceMessageType.allCases
        XCTAssertEqual(allCases.count, 26, "Update tests if message types are added/removed")
    }
}
