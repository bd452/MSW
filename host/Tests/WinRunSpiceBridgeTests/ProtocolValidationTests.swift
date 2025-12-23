import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

/// Tests that validate existing protocol constants match the generated source of truth.
/// These tests ensure the existing types stay in sync with shared/protocol.def.
final class ProtocolValidationTests: XCTestCase {
    // MARK: - Protocol Version

    func testProtocolVersionMatchesGenerated() {
        XCTAssertEqual(SpiceProtocolVersion.major, GeneratedProtocolVersion.major)
        XCTAssertEqual(SpiceProtocolVersion.minor, GeneratedProtocolVersion.minor)
        XCTAssertEqual(SpiceProtocolVersion.combined, GeneratedProtocolVersion.combined)
    }

    // MARK: - Message Types (Host → Guest)

    func testHostToGuestMessageTypesMatchGenerated() {
        XCTAssertEqual(SpiceMessageType.launchProgram.rawValue, GeneratedMessageType.launchProgram.rawValue)
        XCTAssertEqual(SpiceMessageType.requestIcon.rawValue, GeneratedMessageType.requestIcon.rawValue)
        XCTAssertEqual(SpiceMessageType.clipboardData.rawValue, GeneratedMessageType.clipboardData.rawValue)
        XCTAssertEqual(SpiceMessageType.mouseInput.rawValue, GeneratedMessageType.mouseInput.rawValue)
        XCTAssertEqual(SpiceMessageType.keyboardInput.rawValue, GeneratedMessageType.keyboardInput.rawValue)
        XCTAssertEqual(SpiceMessageType.dragDropEvent.rawValue, GeneratedMessageType.dragDropEvent.rawValue)
        XCTAssertEqual(SpiceMessageType.shutdown.rawValue, GeneratedMessageType.shutdown.rawValue)
    }

    // MARK: - Message Types (Guest → Host)

    func testGuestToHostMessageTypesMatchGenerated() {
        XCTAssertEqual(SpiceMessageType.windowMetadata.rawValue, GeneratedMessageType.windowMetadata.rawValue)
        XCTAssertEqual(SpiceMessageType.frameData.rawValue, GeneratedMessageType.frameData.rawValue)
        XCTAssertEqual(SpiceMessageType.capabilityFlags.rawValue, GeneratedMessageType.capabilityFlags.rawValue)
        XCTAssertEqual(SpiceMessageType.dpiInfo.rawValue, GeneratedMessageType.dpiInfo.rawValue)
        XCTAssertEqual(SpiceMessageType.iconData.rawValue, GeneratedMessageType.iconData.rawValue)
        XCTAssertEqual(SpiceMessageType.shortcutDetected.rawValue, GeneratedMessageType.shortcutDetected.rawValue)
        XCTAssertEqual(SpiceMessageType.clipboardChanged.rawValue, GeneratedMessageType.clipboardChanged.rawValue)
        XCTAssertEqual(SpiceMessageType.heartbeat.rawValue, GeneratedMessageType.heartbeat.rawValue)
        XCTAssertEqual(SpiceMessageType.telemetryReport.rawValue, GeneratedMessageType.telemetryReport.rawValue)
    }

    func testProvisioningMessageTypesMatchGenerated() {
        XCTAssertEqual(SpiceMessageType.provisionProgress.rawValue, GeneratedMessageType.provisionProgress.rawValue)
        XCTAssertEqual(SpiceMessageType.provisionError.rawValue, GeneratedMessageType.provisionError.rawValue)
        XCTAssertEqual(SpiceMessageType.provisionComplete.rawValue, GeneratedMessageType.provisionComplete.rawValue)
        XCTAssertEqual(SpiceMessageType.error.rawValue, GeneratedMessageType.error.rawValue)
        XCTAssertEqual(SpiceMessageType.ack.rawValue, GeneratedMessageType.ack.rawValue)
    }

    // MARK: - Guest Capabilities

    func testCapabilitiesMatchGenerated() {
        XCTAssertEqual(GuestCapabilities.windowTracking.rawValue, GeneratedCapabilities.windowTracking.rawValue)
        XCTAssertEqual(GuestCapabilities.desktopDuplication.rawValue, GeneratedCapabilities.desktopDuplication.rawValue)
        XCTAssertEqual(GuestCapabilities.clipboardSync.rawValue, GeneratedCapabilities.clipboardSync.rawValue)
        XCTAssertEqual(GuestCapabilities.dragDrop.rawValue, GeneratedCapabilities.dragDrop.rawValue)
        XCTAssertEqual(GuestCapabilities.iconExtraction.rawValue, GeneratedCapabilities.iconExtraction.rawValue)
        XCTAssertEqual(GuestCapabilities.shortcutDetection.rawValue, GeneratedCapabilities.shortcutDetection.rawValue)
        XCTAssertEqual(GuestCapabilities.highDpiSupport.rawValue, GeneratedCapabilities.highDpiSupport.rawValue)
        XCTAssertEqual(GuestCapabilities.multiMonitor.rawValue, GeneratedCapabilities.multiMonitor.rawValue)
    }

    // MARK: - Input Types

    func testMouseButtonsMatchGenerated() {
        XCTAssertEqual(MouseButton.left.rawValue, GeneratedMouseButton.left.rawValue)
        XCTAssertEqual(MouseButton.right.rawValue, GeneratedMouseButton.right.rawValue)
        XCTAssertEqual(MouseButton.middle.rawValue, GeneratedMouseButton.middle.rawValue)
        XCTAssertEqual(MouseButton.extra1.rawValue, GeneratedMouseButton.extra1.rawValue)
        XCTAssertEqual(MouseButton.extra2.rawValue, GeneratedMouseButton.extra2.rawValue)
    }

    func testMouseEventTypesMatchGenerated() {
        XCTAssertEqual(MouseEventType.move.rawValue, GeneratedMouseEventType.move.rawValue)
        XCTAssertEqual(MouseEventType.press.rawValue, GeneratedMouseEventType.press.rawValue)
        XCTAssertEqual(MouseEventType.release.rawValue, GeneratedMouseEventType.release.rawValue)
        XCTAssertEqual(MouseEventType.scroll.rawValue, GeneratedMouseEventType.scroll.rawValue)
    }

    func testKeyEventTypesMatchGenerated() {
        XCTAssertEqual(KeyEventType.keyDown.rawValue, GeneratedKeyEventType.down.rawValue)
        XCTAssertEqual(KeyEventType.keyUp.rawValue, GeneratedKeyEventType.up.rawValue)
    }

    func testKeyModifiersMatchGenerated() {
        XCTAssertEqual(KeyModifiers.shift.rawValue, GeneratedKeyModifiers.shift.rawValue)
        XCTAssertEqual(KeyModifiers.control.rawValue, GeneratedKeyModifiers.control.rawValue)
        XCTAssertEqual(KeyModifiers.alt.rawValue, GeneratedKeyModifiers.alt.rawValue)
        XCTAssertEqual(KeyModifiers.command.rawValue, GeneratedKeyModifiers.command.rawValue)
        XCTAssertEqual(KeyModifiers.capsLock.rawValue, GeneratedKeyModifiers.capsLock.rawValue)
        XCTAssertEqual(KeyModifiers.numLock.rawValue, GeneratedKeyModifiers.numLock.rawValue)
    }

    // MARK: - Drag and Drop

    func testDragDropEventTypesMatchGenerated() {
        XCTAssertEqual(DragDropEventType.enter.rawValue, GeneratedDragDropEventType.enter.rawValue)
        XCTAssertEqual(DragDropEventType.move.rawValue, GeneratedDragDropEventType.move.rawValue)
        XCTAssertEqual(DragDropEventType.leave.rawValue, GeneratedDragDropEventType.leave.rawValue)
        XCTAssertEqual(DragDropEventType.drop.rawValue, GeneratedDragDropEventType.drop.rawValue)
    }

    func testDragOperationsMatchGenerated() {
        XCTAssertEqual(DragOperation.none.rawValue, GeneratedDragOperation.none.rawValue)
        XCTAssertEqual(DragOperation.copy.rawValue, GeneratedDragOperation.copy.rawValue)
        XCTAssertEqual(DragOperation.move.rawValue, GeneratedDragOperation.move.rawValue)
        XCTAssertEqual(DragOperation.link.rawValue, GeneratedDragOperation.link.rawValue)
    }

    // MARK: - Other Types

    func testPixelFormatsMatchGenerated() {
        XCTAssertEqual(SpicePixelFormat.bgra32.rawValue, GeneratedPixelFormat.bgra32.rawValue)
        XCTAssertEqual(SpicePixelFormat.rgba32.rawValue, GeneratedPixelFormat.rgba32.rawValue)
    }

    func testWindowEventTypesMatchGenerated() {
        XCTAssertEqual(WindowEventType.created.rawValue, GeneratedWindowEventType.created.rawValue)
        XCTAssertEqual(WindowEventType.destroyed.rawValue, GeneratedWindowEventType.destroyed.rawValue)
        XCTAssertEqual(WindowEventType.moved.rawValue, GeneratedWindowEventType.moved.rawValue)
        XCTAssertEqual(WindowEventType.titleChanged.rawValue, GeneratedWindowEventType.titleChanged.rawValue)
        XCTAssertEqual(WindowEventType.focusChanged.rawValue, GeneratedWindowEventType.focusChanged.rawValue)
        XCTAssertEqual(WindowEventType.minimized.rawValue, GeneratedWindowEventType.minimized.rawValue)
        XCTAssertEqual(WindowEventType.restored.rawValue, GeneratedWindowEventType.restored.rawValue)
        XCTAssertEqual(WindowEventType.updated.rawValue, GeneratedWindowEventType.updated.rawValue)
    }

    func testClipboardFormatsMatchGenerated() {
        XCTAssertEqual(ClipboardFormat.plainText.rawValue, GeneratedClipboardFormat.plainText.rawValue)
        XCTAssertEqual(ClipboardFormat.rtf.rawValue, GeneratedClipboardFormat.rtf.rawValue)
        XCTAssertEqual(ClipboardFormat.html.rawValue, GeneratedClipboardFormat.html.rawValue)
        XCTAssertEqual(ClipboardFormat.png.rawValue, GeneratedClipboardFormat.png.rawValue)
        XCTAssertEqual(ClipboardFormat.tiff.rawValue, GeneratedClipboardFormat.tiff.rawValue)
        XCTAssertEqual(ClipboardFormat.fileUrl.rawValue, GeneratedClipboardFormat.fileUrl.rawValue)
    }

    func testProvisioningPhasesMatchGenerated() {
        // Case-insensitive comparison since existing uses lowercase enum case names
        XCTAssertEqual(GuestProvisioningPhase.drivers.rawValue.lowercased(), "drivers")
        XCTAssertEqual(GuestProvisioningPhase.agent.rawValue.lowercased(), "agent")
        XCTAssertEqual(GuestProvisioningPhase.optimize.rawValue.lowercased(), "optimize")
        XCTAssertEqual(GuestProvisioningPhase.finalize.rawValue.lowercased(), "finalize")
        XCTAssertEqual(GuestProvisioningPhase.complete.rawValue.lowercased(), "complete")
    }
}
