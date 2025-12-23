import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

/// Tests that validate existing protocol constants match the generated source of truth.
/// These tests ensure the existing types stay in sync with shared/protocol.def.
final class ProtocolValidationTests: XCTestCase {

    // MARK: - Protocol Version

    func testProtocolVersionMatchesGenerated() {
        XCTAssertEqual(
            SpiceProtocolVersion.major, GeneratedProtocolVersion.major,
            "Protocol major version mismatch - update SpiceProtocol.swift or shared/protocol.def"
        )
        XCTAssertEqual(
            SpiceProtocolVersion.minor, GeneratedProtocolVersion.minor,
            "Protocol minor version mismatch - update SpiceProtocol.swift or shared/protocol.def"
        )
        XCTAssertEqual(
            SpiceProtocolVersion.combined, GeneratedProtocolVersion.combined,
            "Protocol combined version mismatch"
        )
    }

    // MARK: - Message Types

    func testMessageTypesMatchGenerated() {
        // Host → Guest
        XCTAssertEqual(
            SpiceMessageType.launchProgram.rawValue,
            GeneratedMessageType.launchProgram.rawValue,
            "launchProgram message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.requestIcon.rawValue,
            GeneratedMessageType.requestIcon.rawValue,
            "requestIcon message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.clipboardData.rawValue,
            GeneratedMessageType.clipboardData.rawValue,
            "clipboardData message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.mouseInput.rawValue,
            GeneratedMessageType.mouseInput.rawValue,
            "mouseInput message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.keyboardInput.rawValue,
            GeneratedMessageType.keyboardInput.rawValue,
            "keyboardInput message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.dragDropEvent.rawValue,
            GeneratedMessageType.dragDropEvent.rawValue,
            "dragDropEvent message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.shutdown.rawValue,
            GeneratedMessageType.shutdown.rawValue,
            "shutdown message type mismatch"
        )

        // Guest → Host
        XCTAssertEqual(
            SpiceMessageType.windowMetadata.rawValue,
            GeneratedMessageType.windowMetadata.rawValue,
            "windowMetadata message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.frameData.rawValue,
            GeneratedMessageType.frameData.rawValue,
            "frameData message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.capabilityFlags.rawValue,
            GeneratedMessageType.capabilityFlags.rawValue,
            "capabilityFlags message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.dpiInfo.rawValue,
            GeneratedMessageType.dpiInfo.rawValue,
            "dpiInfo message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.iconData.rawValue,
            GeneratedMessageType.iconData.rawValue,
            "iconData message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.shortcutDetected.rawValue,
            GeneratedMessageType.shortcutDetected.rawValue,
            "shortcutDetected message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.clipboardChanged.rawValue,
            GeneratedMessageType.clipboardChanged.rawValue,
            "clipboardChanged message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.heartbeat.rawValue,
            GeneratedMessageType.heartbeat.rawValue,
            "heartbeat message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.telemetryReport.rawValue,
            GeneratedMessageType.telemetryReport.rawValue,
            "telemetryReport message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.provisionProgress.rawValue,
            GeneratedMessageType.provisionProgress.rawValue,
            "provisionProgress message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.provisionError.rawValue,
            GeneratedMessageType.provisionError.rawValue,
            "provisionError message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.provisionComplete.rawValue,
            GeneratedMessageType.provisionComplete.rawValue,
            "provisionComplete message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.error.rawValue,
            GeneratedMessageType.error.rawValue,
            "error message type mismatch"
        )
        XCTAssertEqual(
            SpiceMessageType.ack.rawValue,
            GeneratedMessageType.ack.rawValue,
            "ack message type mismatch"
        )
    }

    // MARK: - Guest Capabilities

    func testCapabilitiesMatchGenerated() {
        XCTAssertEqual(
            GuestCapabilities.windowTracking.rawValue,
            GeneratedCapabilities.windowTracking.rawValue,
            "windowTracking capability mismatch"
        )
        XCTAssertEqual(
            GuestCapabilities.desktopDuplication.rawValue,
            GeneratedCapabilities.desktopDuplication.rawValue,
            "desktopDuplication capability mismatch"
        )
        XCTAssertEqual(
            GuestCapabilities.clipboardSync.rawValue,
            GeneratedCapabilities.clipboardSync.rawValue,
            "clipboardSync capability mismatch"
        )
        XCTAssertEqual(
            GuestCapabilities.dragDrop.rawValue,
            GeneratedCapabilities.dragDrop.rawValue,
            "dragDrop capability mismatch"
        )
        XCTAssertEqual(
            GuestCapabilities.iconExtraction.rawValue,
            GeneratedCapabilities.iconExtraction.rawValue,
            "iconExtraction capability mismatch"
        )
        XCTAssertEqual(
            GuestCapabilities.shortcutDetection.rawValue,
            GeneratedCapabilities.shortcutDetection.rawValue,
            "shortcutDetection capability mismatch"
        )
        XCTAssertEqual(
            GuestCapabilities.highDpiSupport.rawValue,
            GeneratedCapabilities.highDpiSupport.rawValue,
            "highDpiSupport capability mismatch"
        )
        XCTAssertEqual(
            GuestCapabilities.multiMonitor.rawValue,
            GeneratedCapabilities.multiMonitor.rawValue,
            "multiMonitor capability mismatch"
        )
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
        XCTAssertEqual(
            GuestProvisioningPhase.drivers.rawValue.lowercased(),
            GeneratedProvisioningPhase.drivers.rawValue.lowercased()
        )
        XCTAssertEqual(
            GuestProvisioningPhase.agent.rawValue.lowercased(),
            GeneratedProvisioningPhase.agent.rawValue.lowercased()
        )
        XCTAssertEqual(
            GuestProvisioningPhase.optimize.rawValue.lowercased(),
            GeneratedProvisioningPhase.optimize.rawValue.lowercased()
        )
        XCTAssertEqual(
            GuestProvisioningPhase.finalize.rawValue.lowercased(),
            GeneratedProvisioningPhase.finalize.rawValue.lowercased()
        )
        XCTAssertEqual(
            GuestProvisioningPhase.complete.rawValue.lowercased(),
            GeneratedProvisioningPhase.complete.rawValue.lowercased()
        )
    }
}
