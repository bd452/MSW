import Foundation
import XCTest

@testable import WinRunSpiceBridge

/// Tests that validate protocol types match the shared source of truth (protocol.def)
/// and verify behavioral correctness of the protocol implementation.
///
/// These tests read from shared/protocol-test-data.json which is generated from protocol.def.
/// This ensures Swift and C# implementations stay in sync.
final class ProtocolValidationTests: XCTestCase {
    // MARK: - Shared Test Data

    private static var testData: ProtocolTestData?

    private var testData: ProtocolTestData {
        if let data = Self.testData {
            return data
        }
        let data = Self.loadTestData()
        Self.testData = data
        return data
    }

    private static func loadTestData() -> ProtocolTestData {
        // Find the protocol-test-data.json file
        // Try multiple possible locations
        let possiblePaths = [
            // When running from Xcode or swift test
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()  // Tests/WinRunSpiceBridgeTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // host
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("shared/protocol-test-data.json"),
            // Fallback: relative to current directory
            URL(fileURLWithPath: "shared/protocol-test-data.json"),
            URL(fileURLWithPath: "../../../shared/protocol-test-data.json"),
        ]

        for path in possiblePaths where FileManager.default.fileExists(atPath: path.path) {
            do {
                let data = try Data(contentsOf: path)
                return try JSONDecoder().decode(ProtocolTestData.self, from: data)
            } catch {
                // Try next path
                continue
            }
        }

        // If we can't load the file, return empty data and tests will be skipped
        return ProtocolTestData()
    }

    // MARK: - Cross-Platform Parity Tests

    func testMessageTypesMatchProtocolDef() throws {
        try XCTSkipIf(testData.messageTypesHostToGuest.isEmpty, "Test data not loaded")

        // Host → Guest
        XCTAssertEqual(
            SpiceMessageType.launchProgram.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgLaunchProgram"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.requestIcon.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgRequestIcon"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.clipboardData.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgClipboardData"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.mouseInput.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgMouseInput"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.keyboardInput.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgKeyboardInput"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.dragDropEvent.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgDragDropEvent"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.listSessions.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgListSessions"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.closeSession.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgCloseSession"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.listShortcuts.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgListShortcuts"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.shutdown.rawValue,
            UInt8(testData.messageTypesHostToGuest["msgShutdown"] ?? -1))

        // Guest → Host
        XCTAssertEqual(
            SpiceMessageType.windowMetadata.rawValue,
            UInt8(testData.messageTypesGuestToHost["msgWindowMetadata"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.frameData.rawValue,
            UInt8(testData.messageTypesGuestToHost["msgFrameData"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.capabilityFlags.rawValue,
            UInt8(testData.messageTypesGuestToHost["msgCapabilityFlags"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.error.rawValue,
            UInt8(testData.messageTypesGuestToHost["msgError"] ?? -1))
        XCTAssertEqual(
            SpiceMessageType.ack.rawValue,
            UInt8(testData.messageTypesGuestToHost["msgAck"] ?? -1))
    }

    func testCapabilitiesMatchProtocolDef() throws {
        try XCTSkipIf(testData.capabilities.isEmpty, "Test data not loaded")

        XCTAssertEqual(
            GuestCapabilities.windowTracking.rawValue,
            UInt32(testData.capabilities["capWindowTracking"] ?? -1))
        XCTAssertEqual(
            GuestCapabilities.desktopDuplication.rawValue,
            UInt32(testData.capabilities["capDesktopDuplication"] ?? -1))
        XCTAssertEqual(
            GuestCapabilities.clipboardSync.rawValue,
            UInt32(testData.capabilities["capClipboardSync"] ?? -1))
        XCTAssertEqual(
            GuestCapabilities.iconExtraction.rawValue,
            UInt32(testData.capabilities["capIconExtraction"] ?? -1))
    }

    // MARK: - Behavioral Tests: Message Direction

    func testHostToGuestMessagesAreInCorrectRange() {
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

    func testGuestToHostMessagesAreInCorrectRange() {
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

    // MARK: - Behavioral Tests: Capabilities

    func testCapabilitiesArePowersOfTwo() {
        let capabilities: [GuestCapabilities] = [
            .windowTracking, .desktopDuplication, .clipboardSync, .dragDrop,
            .iconExtraction, .shortcutDetection, .highDpiSupport, .multiMonitor,
        ]

        for cap in capabilities {
            let value = cap.rawValue
            // Power of 2 check: value & (value - 1) == 0 for powers of 2
            XCTAssertEqual(value & (value - 1), 0, "\(cap) should be a power of 2")
            XCTAssertGreaterThan(value, 0, "\(cap) should be non-zero")
        }
    }

    func testCapabilitiesCanBeCombined() {
        let combined: GuestCapabilities = [.windowTracking, .clipboardSync, .iconExtraction]

        XCTAssertTrue(combined.contains(.windowTracking))
        XCTAssertTrue(combined.contains(.clipboardSync))
        XCTAssertTrue(combined.contains(.iconExtraction))
        XCTAssertFalse(combined.contains(.dragDrop))
    }

    func testAllCoreCapabilitiesIncludesExpectedFlags() {
        let allCore = GuestCapabilities.allCore

        XCTAssertTrue(allCore.contains(.windowTracking))
        XCTAssertTrue(allCore.contains(.desktopDuplication))
        XCTAssertTrue(allCore.contains(.clipboardSync))
        XCTAssertTrue(allCore.contains(.iconExtraction))
    }

    // MARK: - Behavioral Tests: Protocol Version

    func testProtocolVersionCombinedFormat() {
        // Combined format: upper 16 bits = major, lower 16 bits = minor
        let combined = SpiceProtocolVersion.combined
        let major = UInt16(combined >> 16)
        let minor = UInt16(combined & 0xFFFF)

        XCTAssertEqual(major, SpiceProtocolVersion.major)
        XCTAssertEqual(minor, SpiceProtocolVersion.minor)
    }

    func testProtocolVersionCompatibility() {
        let current = SpiceProtocolVersion.combined

        // Same version is compatible
        XCTAssertTrue(SpiceProtocolVersion.isCompatible(with: current))

        // Same major, lower minor is compatible
        let olderMinor = (UInt32(SpiceProtocolVersion.major) << 16) | 0
        XCTAssertTrue(SpiceProtocolVersion.isCompatible(with: olderMinor))

        // Different major is incompatible
        let differentMajor = (UInt32(SpiceProtocolVersion.major + 1) << 16) | 0
        XCTAssertFalse(SpiceProtocolVersion.isCompatible(with: differentMajor))
    }

    func testProtocolVersionParsing() {
        let combined: UInt32 = 0x0001_0002  // major=1, minor=2
        let (major, minor) = SpiceProtocolVersion.parse(combined)

        XCTAssertEqual(major, 1)
        XCTAssertEqual(minor, 2)
    }

    func testProtocolVersionFormatting() {
        let combined: UInt32 = 0x0001_0002
        let formatted = SpiceProtocolVersion.format(combined)

        XCTAssertEqual(formatted, "1.2")
    }

    // MARK: - Behavioral Tests: Key Modifiers

    func testKeyModifiersCanBeCombined() {
        let combined: KeyModifiers = [.shift, .control, .alt]

        XCTAssertTrue(combined.contains(.shift))
        XCTAssertTrue(combined.contains(.control))
        XCTAssertTrue(combined.contains(.alt))
        XCTAssertFalse(combined.contains(.command))
    }

    // MARK: - Completeness Tests

    func testAllMessageTypesExist() {
        // Verify we have all expected message types
        let allCases = SpiceMessageType.allCases
        XCTAssertEqual(allCases.count, 26, "Expected 26 message types")

        // Verify no duplicate raw values
        let rawValues = allCases.map { $0.rawValue }
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "All message types should have unique values")
    }

    func testAllClipboardFormatsExist() {
        let allCases = ClipboardFormat.allCases
        XCTAssertGreaterThanOrEqual(allCases.count, 6)

        // Verify expected formats exist
        XCTAssertNotNil(ClipboardFormat(rawValue: "plainText"))
        XCTAssertNotNil(ClipboardFormat(rawValue: "rtf"))
        XCTAssertNotNil(ClipboardFormat(rawValue: "html"))
        XCTAssertNotNil(ClipboardFormat(rawValue: "png"))
    }

    func testAllProvisioningPhasesExist() {
        let allCases = GuestProvisioningPhase.allCases
        XCTAssertEqual(allCases.count, 5)

        XCTAssertNotNil(GuestProvisioningPhase(rawValue: "drivers"))
        XCTAssertNotNil(GuestProvisioningPhase(rawValue: "agent"))
        XCTAssertNotNil(GuestProvisioningPhase(rawValue: "optimize"))
        XCTAssertNotNil(GuestProvisioningPhase(rawValue: "finalize"))
        XCTAssertNotNil(GuestProvisioningPhase(rawValue: "complete"))
    }
}

// MARK: - Test Data Model

private struct ProtocolTestData: Decodable {
    var version: [String: Int] = [:]
    var messageTypesHostToGuest: [String: Int] = [:]
    var messageTypesGuestToHost: [String: Int] = [:]
    var capabilities: [String: Int] = [:]
    var mouseButtons: [String: Int] = [:]
    var mouseEventTypes: [String: Int] = [:]
    var keyEventTypes: [String: Int] = [:]
    var keyModifiers: [String: Int] = [:]
    var dragDropEventTypes: [String: Int] = [:]
    var dragOperations: [String: Int] = [:]
    var pixelFormats: [String: Int] = [:]
    var windowEventTypes: [String: Int] = [:]
    var clipboardFormats: [String: String] = [:]
    var provisioningPhases: [String: String] = [:]
}
