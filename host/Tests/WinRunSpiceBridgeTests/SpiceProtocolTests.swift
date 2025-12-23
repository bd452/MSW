import Foundation
import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - Protocol Version Tests

final class SpiceProtocolVersionTests: XCTestCase {
    func testCombinedVersionFormat() {
        let combined = SpiceProtocolVersion.combined
        let major = UInt16(combined >> 16)
        let minor = UInt16(combined & 0xFFFF)

        XCTAssertEqual(major, SpiceProtocolVersion.major)
        XCTAssertEqual(minor, SpiceProtocolVersion.minor)
    }

    func testParseExtractsMajorAndMinor() {
        let version: UInt32 = (2 << 16) | 5
        let (major, minor) = SpiceProtocolVersion.parse(version)

        XCTAssertEqual(major, 2)
        XCTAssertEqual(minor, 5)
    }

    func testFormatProducesCorrectString() {
        let version: UInt32 = (1 << 16) | 0
        let formatted = SpiceProtocolVersion.format(version)

        XCTAssertEqual(formatted, "1.0")
    }

    func testCompatibleWithSameMajorVersion() {
        let guestVersion = SpiceProtocolVersion.combined
        XCTAssertTrue(SpiceProtocolVersion.isCompatible(with: guestVersion))
    }

    func testCompatibleWithOlderMinorVersion() {
        // Guest has older minor version (0), host is 1.0
        let guestVersion: UInt32 = (1 << 16) | 0
        XCTAssertTrue(SpiceProtocolVersion.isCompatible(with: guestVersion))
    }

    func testIncompatibleWithDifferentMajorVersion() {
        let guestVersion: UInt32 = (2 << 16) | 0  // Version 2.0
        XCTAssertFalse(SpiceProtocolVersion.isCompatible(with: guestVersion))
    }

    func testIncompatibleWithNewerMinorVersion() {
        // Guest has minor version 1, host is 1.0
        let guestVersion: UInt32 = (1 << 16) | 1
        XCTAssertFalse(SpiceProtocolVersion.isCompatible(with: guestVersion))
    }

    func testVersionString() {
        let expected = "\(SpiceProtocolVersion.major).\(SpiceProtocolVersion.minor)"
        XCTAssertEqual(SpiceProtocolVersion.versionString, expected)
    }
}

// MARK: - Message Type Tests

final class SpiceMessageTypeTests: XCTestCase {
    func testHostToGuestTypesHaveCorrectRange() {
        let hostTypes: [SpiceMessageType] = [
            .launchProgram, .requestIcon, .clipboardData,
            .mouseInput, .keyboardInput, .dragDropEvent, .shutdown,
        ]

        for type in hostTypes {
            XCTAssertTrue(type.isHostToGuest, "\(type) should be host-to-guest")
            XCTAssertFalse(type.isGuestToHost, "\(type) should not be guest-to-host")
            XCTAssertTrue(type.rawValue < 0x80, "\(type) rawValue should be < 0x80")
        }
    }

    func testGuestToHostTypesHaveCorrectRange() {
        let guestTypes: [SpiceMessageType] = [
            .windowMetadata, .frameData, .capabilityFlags, .dpiInfo,
            .iconData, .shortcutDetected, .clipboardChanged,
            .heartbeat, .telemetryReport,
            .provisionProgress, .provisionError, .provisionComplete,
            .sessionList, .error, .ack,
        ]

        for type in guestTypes {
            XCTAssertTrue(type.isGuestToHost, "\(type) should be guest-to-host")
            XCTAssertFalse(type.isHostToGuest, "\(type) should not be host-to-guest")
            XCTAssertTrue(type.rawValue >= 0x80, "\(type) rawValue should be >= 0x80")
        }
    }

    func testRawValuesMatchGuestCSharpEnum() {
        // Verify key message types match the C# SpiceMessageType enum
        XCTAssertEqual(SpiceMessageType.launchProgram.rawValue, 0x01)
        XCTAssertEqual(SpiceMessageType.requestIcon.rawValue, 0x02)
        XCTAssertEqual(SpiceMessageType.clipboardData.rawValue, 0x03)
        XCTAssertEqual(SpiceMessageType.mouseInput.rawValue, 0x04)
        XCTAssertEqual(SpiceMessageType.keyboardInput.rawValue, 0x05)
        XCTAssertEqual(SpiceMessageType.dragDropEvent.rawValue, 0x06)
        XCTAssertEqual(SpiceMessageType.listSessions.rawValue, 0x08)
        XCTAssertEqual(SpiceMessageType.closeSession.rawValue, 0x09)
        XCTAssertEqual(SpiceMessageType.shutdown.rawValue, 0x0F)

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
        XCTAssertEqual(SpiceMessageType.error.rawValue, 0xFE)
        XCTAssertEqual(SpiceMessageType.ack.rawValue, 0xFF)
    }

    func testSessionMessageTypesHaveCorrectDirection() {
        // ListSessions and CloseSession are host-to-guest
        XCTAssertTrue(SpiceMessageType.listSessions.isHostToGuest)
        XCTAssertTrue(SpiceMessageType.closeSession.isHostToGuest)

        // SessionList is guest-to-host
        XCTAssertTrue(SpiceMessageType.sessionList.isGuestToHost)
    }
}

// MARK: - Guest Capabilities Tests

final class GuestCapabilitiesTests: XCTestCase {
    func testRawValuesMatchGuestCSharpEnum() {
        XCTAssertEqual(GuestCapabilities.windowTracking.rawValue, 1 << 0)
        XCTAssertEqual(GuestCapabilities.desktopDuplication.rawValue, 1 << 1)
        XCTAssertEqual(GuestCapabilities.clipboardSync.rawValue, 1 << 2)
        XCTAssertEqual(GuestCapabilities.dragDrop.rawValue, 1 << 3)
        XCTAssertEqual(GuestCapabilities.iconExtraction.rawValue, 1 << 4)
        XCTAssertEqual(GuestCapabilities.shortcutDetection.rawValue, 1 << 5)
        XCTAssertEqual(GuestCapabilities.highDpiSupport.rawValue, 1 << 6)
        XCTAssertEqual(GuestCapabilities.multiMonitor.rawValue, 1 << 7)
    }

    func testAllCoreContainsExpectedCapabilities() {
        let core = GuestCapabilities.allCore

        XCTAssertTrue(core.contains(.windowTracking))
        XCTAssertTrue(core.contains(.desktopDuplication))
        XCTAssertTrue(core.contains(.clipboardSync))
        XCTAssertTrue(core.contains(.iconExtraction))
    }

    func testDescriptionListsEnabledCapabilities() {
        let caps: GuestCapabilities = [.windowTracking, .clipboardSync]
        let desc = caps.description

        XCTAssertTrue(desc.contains("windowTracking"))
        XCTAssertTrue(desc.contains("clipboardSync"))
        XCTAssertFalse(desc.contains("desktopDuplication"))
    }

    func testOptionSetOperations() {
        var caps: GuestCapabilities = [.windowTracking]
        caps.insert(.clipboardSync)

        XCTAssertTrue(caps.contains(.windowTracking))
        XCTAssertTrue(caps.contains(.clipboardSync))
        XCTAssertFalse(caps.contains(.dragDrop))

        let combined = GuestCapabilities.windowTracking.union(.clipboardSync)
        XCTAssertEqual(combined, caps)
    }
}

// MARK: - Message Serialization Tests

final class SpiceMessageSerializerTests: XCTestCase {
    func testSerializeLaunchProgramMessage() throws {
        let message = LaunchProgramSpiceMessage(
            messageId: 42,
            path: "C:\\Windows\\notepad.exe",
            arguments: ["/p", "test.txt"],
            workingDirectory: "C:\\Users\\Test"
        )

        let data = try SpiceMessageSerializer.serialize(message)

        // Check envelope format: [Type:1][Length:4][Payload:N]
        XCTAssertGreaterThanOrEqual(data.count, 5)
        XCTAssertEqual(data[0], SpiceMessageType.launchProgram.rawValue)

        // Read length bytes individually to avoid alignment issues
        let length =
            UInt32(data[1]) | (UInt32(data[2]) << 8) | (UInt32(data[3]) << 16)
            | (UInt32(data[4]) << 24)
        XCTAssertEqual(data.count, 5 + Int(length))
    }

    func testSerializeMouseInputMessage() throws {
        let message = MouseInputSpiceMessage(
            messageId: 1,
            windowId: 12345,
            eventType: .press,
            button: .left,
            x: 100.5,
            y: 200.5,
            modifiers: .shift
        )

        let data = try SpiceMessageSerializer.serialize(message)

        XCTAssertEqual(data[0], SpiceMessageType.mouseInput.rawValue)
    }

    func testSerializeKeyboardInputMessage() throws {
        let message = KeyboardInputSpiceMessage(
            messageId: 2,
            windowId: 12345,
            eventType: .down,
            keyCode: 0x41,  // 'A'
            scanCode: 0x1E,
            modifiers: [.control, .shift]
        )

        let data = try SpiceMessageSerializer.serialize(message)

        XCTAssertEqual(data[0], SpiceMessageType.keyboardInput.rawValue)
    }

    func testSerializeShutdownMessage() throws {
        let message = ShutdownSpiceMessage(messageId: 99, timeoutMs: 10000)

        let data = try SpiceMessageSerializer.serialize(message)

        XCTAssertEqual(data[0], SpiceMessageType.shutdown.rawValue)
    }

    func testSerializeListSessionsMessage() throws {
        let message = ListSessionsSpiceMessage(messageId: 100)

        let data = try SpiceMessageSerializer.serialize(message)

        XCTAssertEqual(data[0], SpiceMessageType.listSessions.rawValue)
    }

    func testSerializeCloseSessionMessage() throws {
        let message = CloseSessionSpiceMessage(messageId: 101, sessionId: "1234")

        let data = try SpiceMessageSerializer.serialize(message)

        XCTAssertEqual(data[0], SpiceMessageType.closeSession.rawValue)
    }

    func testDeserializeSessionListMessage() throws {
        let sessionInfo = SpiceSessionInfo(
            sessionId: "1234",
            processId: 1234,
            executablePath: "C:\\Windows\\notepad.exe",
            windowTitle: "Untitled - Notepad",
            startTimeMs: 1700000000000,
            lastActivityMs: 1700000001000,
            state: .active,
            windowCount: 1
        )

        let original = SessionListMessage(
            messageId: 100,
            sessions: [sessionInfo]
        )

        let encoder = JSONEncoder()
        let payload = try encoder.encode(original)

        var envelope = Data()
        envelope.append(SpiceMessageType.sessionList.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        let result = try SpiceMessageSerializer.deserialize(envelope)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, .sessionList)

        if let message = result?.1 as? SessionListMessage {
            XCTAssertEqual(message.messageId, 100)
            XCTAssertEqual(message.sessions.count, 1)
            XCTAssertEqual(message.sessions[0].sessionId, "1234")
            XCTAssertEqual(message.sessions[0].processId, 1234)
            XCTAssertEqual(message.sessions[0].state, .active)
        } else {
            XCTFail("Expected SessionListMessage")
        }
    }

    func testSessionListMessageToGuestSessionList() throws {
        let sessionInfo = SpiceSessionInfo(
            sessionId: "5678",
            processId: 5678,
            executablePath: "C:\\Program Files\\App\\app.exe",
            windowTitle: "My App",
            startTimeMs: 1700000000000,
            lastActivityMs: 1700000001000,
            state: .active,
            windowCount: 2
        )

        let message = SessionListMessage(messageId: 1, sessions: [sessionInfo])
        let guestSessionList = message.toGuestSessionList()

        XCTAssertEqual(guestSessionList.sessions.count, 1)
        XCTAssertEqual(guestSessionList.sessions[0].id, "5678")
        XCTAssertEqual(guestSessionList.sessions[0].windowsPath, "C:\\Program Files\\App\\app.exe")
        XCTAssertEqual(guestSessionList.sessions[0].windowTitle, "My App")
        XCTAssertEqual(guestSessionList.sessions[0].processId, 5678)
    }

    func testSpiceSessionInfoToGuestSession() {
        let sessionInfo = SpiceSessionInfo(
            sessionId: "9999",
            processId: 9999,
            executablePath: "C:\\test.exe",
            windowTitle: "Test Window",
            startTimeMs: 1700000000000,
            lastActivityMs: 1700000001000,
            state: .idle,
            windowCount: 0
        )

        let guestSession = sessionInfo.toGuestSession()

        XCTAssertEqual(guestSession.id, "9999")
        XCTAssertEqual(guestSession.windowsPath, "C:\\test.exe")
        XCTAssertEqual(guestSession.windowTitle, "Test Window")
        XCTAssertEqual(guestSession.processId, 9999)
    }

    func testDeserializeCapabilityFlagsMessage() throws {
        let capabilities: GuestCapabilities = [.windowTracking, .clipboardSync]
        let original = CapabilityFlagsMessage(
            capabilities: capabilities,
            protocolVersion: SpiceProtocolVersion.combined,
            agentVersion: "1.0.0",
            osVersion: "Windows 11"
        )

        // Create envelope manually using camelCase to match guest's serialization
        let encoder = JSONEncoder()
        // Default key encoding is camelCase (no strategy set) to match guest's JsonNamingPolicy.CamelCase
        let payload = try encoder.encode(original)

        var envelope = Data()
        envelope.append(SpiceMessageType.capabilityFlags.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        let result = try SpiceMessageSerializer.deserialize(envelope)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, .capabilityFlags)

        if let message = result?.1 as? CapabilityFlagsMessage {
            XCTAssertEqual(message.capabilities, capabilities)
            XCTAssertEqual(message.protocolVersion, SpiceProtocolVersion.combined)
            XCTAssertEqual(message.agentVersion, "1.0.0")
        } else {
            XCTFail("Expected CapabilityFlagsMessage")
        }
    }

    func testTryReadMessageFromIncompleteBuffer() throws {
        // Only 3 bytes, need at least 5
        let buffer = Data([0x80, 0x00, 0x00])

        let result = try SpiceMessageSerializer.tryReadMessage(from: buffer)

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.bytesConsumed, 0)
    }

    func testTryReadMessageWithIncompletePayload() throws {
        // Header says 100 bytes but only 5 total provided
        var buffer = Data()
        buffer.append(SpiceMessageType.heartbeat.rawValue)
        var length = UInt32(100).littleEndian
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }

        let result = try SpiceMessageSerializer.tryReadMessage(from: buffer)

        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.bytesConsumed, 0)
    }

    func testDeserializeReturnsNilForIncompleteData() throws {
        let result = try SpiceMessageSerializer.deserialize(Data([0x80, 0x00]))

        XCTAssertNil(result)
    }

    func testInvalidMessageTypeThrowsError() {
        var buffer = Data()
        buffer.append(0x50)  // Invalid type not in enum
        var length = UInt32(0).littleEndian
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }

        XCTAssertThrowsError(try SpiceMessageSerializer.deserialize(buffer)) { error in
            XCTAssertTrue(error is SpiceProtocolError)
        }
    }
}

// MARK: - Version Negotiation Tests

final class VersionNegotiationResultTests: XCTestCase {
    func testCreatesFromCapabilityMessage() {
        let capabilities: GuestCapabilities = [.windowTracking, .desktopDuplication]
        let message = CapabilityFlagsMessage(
            capabilities: capabilities,
            protocolVersion: SpiceProtocolVersion.combined,
            agentVersion: "1.2.3",
            osVersion: "Windows 11 Pro"
        )

        let result = VersionNegotiationResult(from: message)

        XCTAssertTrue(result.isCompatible)
        XCTAssertEqual(result.hostVersion, SpiceProtocolVersion.combined)
        XCTAssertEqual(result.guestVersion, SpiceProtocolVersion.combined)
        XCTAssertEqual(result.guestCapabilities, capabilities)
        XCTAssertEqual(result.guestAgentVersion, "1.2.3")
        XCTAssertEqual(result.guestOsVersion, "Windows 11 Pro")
    }

    func testDetectsIncompatibleVersion() {
        let message = CapabilityFlagsMessage(
            capabilities: .allCore,
            protocolVersion: (2 << 16) | 0,  // Version 2.0
            agentVersion: "2.0.0",
            osVersion: "Windows 12"
        )

        let result = VersionNegotiationResult(from: message)

        XCTAssertFalse(result.isCompatible)
    }

    func testDescriptionIncludesAllFields() {
        let message = CapabilityFlagsMessage(
            capabilities: [.windowTracking],
            protocolVersion: SpiceProtocolVersion.combined,
            agentVersion: "1.0.0",
            osVersion: "Windows 11"
        )

        let result = VersionNegotiationResult(from: message)
        let desc = result.description

        XCTAssertTrue(desc.contains("Version Negotiation"))
        XCTAssertTrue(desc.contains("Host:"))
        XCTAssertTrue(desc.contains("Guest:"))
        XCTAssertTrue(desc.contains("Compatible:"))
    }
}

// MARK: - RectInfo Tests

final class RectInfoTests: XCTestCase {
    func testInitialization() {
        let rect = RectInfo(x: 10, y: 20, width: 100, height: 200)

        XCTAssertEqual(rect.x, 10)
        XCTAssertEqual(rect.y, 20)
        XCTAssertEqual(rect.width, 100)
        XCTAssertEqual(rect.height, 200)
    }

    func testCodableRoundTrip() throws {
        let original = RectInfo(x: -10, y: -20, width: 1920, height: 1080)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RectInfo.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testHashable() {
        let rect1 = RectInfo(x: 0, y: 0, width: 100, height: 100)
        let rect2 = RectInfo(x: 0, y: 0, width: 100, height: 100)
        let rect3 = RectInfo(x: 1, y: 0, width: 100, height: 100)

        XCTAssertEqual(rect1.hashValue, rect2.hashValue)
        XCTAssertNotEqual(rect1.hashValue, rect3.hashValue)

        var set: Set<RectInfo> = [rect1]
        set.insert(rect2)
        XCTAssertEqual(set.count, 1)

        set.insert(rect3)
        XCTAssertEqual(set.count, 2)
    }
}
