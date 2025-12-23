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
    // Note: Existing types use Int32, generated types use UInt8. Since the wire format is JSON
    // (type-agnostic), we compare numeric values by casting to Int.

    func testMouseButtonsMatchGenerated() {
        XCTAssertEqual(Int(MouseButton.left.rawValue), Int(GeneratedMouseButton.left.rawValue))
        XCTAssertEqual(Int(MouseButton.right.rawValue), Int(GeneratedMouseButton.right.rawValue))
        XCTAssertEqual(Int(MouseButton.middle.rawValue), Int(GeneratedMouseButton.middle.rawValue))
        XCTAssertEqual(Int(MouseButton.extra1.rawValue), Int(GeneratedMouseButton.extra1.rawValue))
        XCTAssertEqual(Int(MouseButton.extra2.rawValue), Int(GeneratedMouseButton.extra2.rawValue))
    }

    func testMouseEventTypesMatchGenerated() {
        XCTAssertEqual(Int(MouseEventType.move.rawValue), Int(GeneratedMouseEventType.move.rawValue))
        XCTAssertEqual(Int(MouseEventType.press.rawValue), Int(GeneratedMouseEventType.press.rawValue))
        XCTAssertEqual(Int(MouseEventType.release.rawValue), Int(GeneratedMouseEventType.release.rawValue))
        XCTAssertEqual(Int(MouseEventType.scroll.rawValue), Int(GeneratedMouseEventType.scroll.rawValue))
    }

    func testKeyEventTypesMatchGenerated() {
        XCTAssertEqual(Int(KeyEventType.keyDown.rawValue), Int(GeneratedKeyEventType.down.rawValue))
        XCTAssertEqual(Int(KeyEventType.keyUp.rawValue), Int(GeneratedKeyEventType.up.rawValue))
    }

    func testKeyModifiersMatchGenerated() {
        XCTAssertEqual(Int(KeyModifiers.shift.rawValue), Int(GeneratedKeyModifiers.shift.rawValue))
        XCTAssertEqual(Int(KeyModifiers.control.rawValue), Int(GeneratedKeyModifiers.control.rawValue))
        XCTAssertEqual(Int(KeyModifiers.alt.rawValue), Int(GeneratedKeyModifiers.alt.rawValue))
        XCTAssertEqual(Int(KeyModifiers.command.rawValue), Int(GeneratedKeyModifiers.command.rawValue))
        XCTAssertEqual(Int(KeyModifiers.capsLock.rawValue), Int(GeneratedKeyModifiers.capsLock.rawValue))
        XCTAssertEqual(Int(KeyModifiers.numLock.rawValue), Int(GeneratedKeyModifiers.numLock.rawValue))
    }

    // MARK: - Drag and Drop

    func testDragDropEventTypesMatchGenerated() {
        XCTAssertEqual(Int(DragDropEventType.enter.rawValue), Int(GeneratedDragDropEventType.enter.rawValue))
        XCTAssertEqual(Int(DragDropEventType.move.rawValue), Int(GeneratedDragDropEventType.move.rawValue))
        XCTAssertEqual(Int(DragDropEventType.leave.rawValue), Int(GeneratedDragDropEventType.leave.rawValue))
        XCTAssertEqual(Int(DragDropEventType.drop.rawValue), Int(GeneratedDragDropEventType.drop.rawValue))
    }

    func testDragOperationsMatchGenerated() {
        XCTAssertEqual(Int(DragOperation.none.rawValue), Int(GeneratedDragOperation.none.rawValue))
        XCTAssertEqual(Int(DragOperation.copy.rawValue), Int(GeneratedDragOperation.copy.rawValue))
        XCTAssertEqual(Int(DragOperation.move.rawValue), Int(GeneratedDragOperation.move.rawValue))
        XCTAssertEqual(Int(DragOperation.link.rawValue), Int(GeneratedDragOperation.link.rawValue))
    }

    // MARK: - Other Types

    func testPixelFormatsMatchGenerated() {
        XCTAssertEqual(Int(SpicePixelFormat.bgra32.rawValue), Int(GeneratedPixelFormat.bgra32.rawValue))
        XCTAssertEqual(Int(SpicePixelFormat.rgba32.rawValue), Int(GeneratedPixelFormat.rgba32.rawValue))
    }

    func testWindowEventTypesMatchGenerated() {
        XCTAssertEqual(Int(WindowEventType.created.rawValue), Int(GeneratedWindowEventType.created.rawValue))
        XCTAssertEqual(Int(WindowEventType.destroyed.rawValue), Int(GeneratedWindowEventType.destroyed.rawValue))
        XCTAssertEqual(Int(WindowEventType.moved.rawValue), Int(GeneratedWindowEventType.moved.rawValue))
        XCTAssertEqual(Int(WindowEventType.titleChanged.rawValue), Int(GeneratedWindowEventType.titleChanged.rawValue))
        XCTAssertEqual(Int(WindowEventType.focusChanged.rawValue), Int(GeneratedWindowEventType.focusChanged.rawValue))
        XCTAssertEqual(Int(WindowEventType.minimized.rawValue), Int(GeneratedWindowEventType.minimized.rawValue))
        XCTAssertEqual(Int(WindowEventType.restored.rawValue), Int(GeneratedWindowEventType.restored.rawValue))
        XCTAssertEqual(Int(WindowEventType.updated.rawValue), Int(GeneratedWindowEventType.updated.rawValue))
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
