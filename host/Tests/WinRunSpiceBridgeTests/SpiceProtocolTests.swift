import Foundation
import Testing
@testable import WinRunSpiceBridge
@testable import WinRunShared

// MARK: - Protocol Version Tests

@Suite("SpiceProtocolVersion")
struct SpiceProtocolVersionTests {
    @Test("Combined version format is correct")
    func combinedVersionFormat() {
        let combined = SpiceProtocolVersion.combined
        let major = UInt16(combined >> 16)
        let minor = UInt16(combined & 0xFFFF)

        #expect(major == SpiceProtocolVersion.major)
        #expect(minor == SpiceProtocolVersion.minor)
    }

    @Test("Parse extracts major and minor correctly")
    func parseVersion() {
        let version: UInt32 = (2 << 16) | 5
        let (major, minor) = SpiceProtocolVersion.parse(version)

        #expect(major == 2)
        #expect(minor == 5)
    }

    @Test("Format produces correct string")
    func formatVersion() {
        let version: UInt32 = (1 << 16) | 0
        let formatted = SpiceProtocolVersion.format(version)

        #expect(formatted == "1.0")
    }

    @Test("Compatible with same major version")
    func compatibleSameMajor() {
        let guestVersion = SpiceProtocolVersion.combined
        #expect(SpiceProtocolVersion.isCompatible(with: guestVersion))
    }

    @Test("Compatible with older minor version")
    func compatibleOlderMinor() {
        // Guest has older minor version (0), host is 1.0
        let guestVersion: UInt32 = (1 << 16) | 0
        #expect(SpiceProtocolVersion.isCompatible(with: guestVersion))
    }

    @Test("Incompatible with different major version")
    func incompatibleDifferentMajor() {
        let guestVersion: UInt32 = (2 << 16) | 0  // Version 2.0
        #expect(!SpiceProtocolVersion.isCompatible(with: guestVersion))
    }

    @Test("Incompatible with newer minor version")
    func incompatibleNewerMinor() {
        // Guest has minor version 1, host is 1.0
        let guestVersion: UInt32 = (1 << 16) | 1
        #expect(!SpiceProtocolVersion.isCompatible(with: guestVersion))
    }

    @Test("Version string is formatted correctly")
    func versionString() {
        let expected = "\(SpiceProtocolVersion.major).\(SpiceProtocolVersion.minor)"
        #expect(SpiceProtocolVersion.versionString == expected)
    }
}

// MARK: - Message Type Tests

@Suite("SpiceMessageType")
struct SpiceMessageTypeTests {
    @Test("Host to guest types have correct range")
    func hostToGuestRange() {
        let hostTypes: [SpiceMessageType] = [
            .launchProgram, .requestIcon, .clipboardData,
            .mouseInput, .keyboardInput, .dragDropEvent, .shutdown
        ]

        for type in hostTypes {
            #expect(type.isHostToGuest)
            #expect(!type.isGuestToHost)
            #expect(type.rawValue < 0x80)
        }
    }

    @Test("Guest to host types have correct range")
    func guestToHostRange() {
        let guestTypes: [SpiceMessageType] = [
            .windowMetadata, .frameData, .capabilityFlags, .dpiInfo,
            .iconData, .shortcutDetected, .clipboardChanged,
            .heartbeat, .telemetryReport, .error, .ack
        ]

        for type in guestTypes {
            #expect(type.isGuestToHost)
            #expect(!type.isHostToGuest)
            #expect(type.rawValue >= 0x80)
        }
    }

    @Test("Raw values match guest C# enum")
    func rawValuesMatchGuest() {
        // Verify key message types match the C# SpiceMessageType enum
        #expect(SpiceMessageType.launchProgram.rawValue == 0x01)
        #expect(SpiceMessageType.requestIcon.rawValue == 0x02)
        #expect(SpiceMessageType.clipboardData.rawValue == 0x03)
        #expect(SpiceMessageType.mouseInput.rawValue == 0x04)
        #expect(SpiceMessageType.keyboardInput.rawValue == 0x05)
        #expect(SpiceMessageType.dragDropEvent.rawValue == 0x06)
        #expect(SpiceMessageType.shutdown.rawValue == 0x0F)

        #expect(SpiceMessageType.windowMetadata.rawValue == 0x80)
        #expect(SpiceMessageType.frameData.rawValue == 0x81)
        #expect(SpiceMessageType.capabilityFlags.rawValue == 0x82)
        #expect(SpiceMessageType.dpiInfo.rawValue == 0x83)
        #expect(SpiceMessageType.iconData.rawValue == 0x84)
        #expect(SpiceMessageType.shortcutDetected.rawValue == 0x85)
        #expect(SpiceMessageType.clipboardChanged.rawValue == 0x86)
        #expect(SpiceMessageType.heartbeat.rawValue == 0x87)
        #expect(SpiceMessageType.telemetryReport.rawValue == 0x88)
        #expect(SpiceMessageType.error.rawValue == 0xFE)
        #expect(SpiceMessageType.ack.rawValue == 0xFF)
    }
}

// MARK: - Guest Capabilities Tests

@Suite("GuestCapabilities")
struct GuestCapabilitiesTests {
    @Test("Raw values match guest C# enum")
    func rawValuesMatchGuest() {
        #expect(GuestCapabilities.windowTracking.rawValue == 1 << 0)
        #expect(GuestCapabilities.desktopDuplication.rawValue == 1 << 1)
        #expect(GuestCapabilities.clipboardSync.rawValue == 1 << 2)
        #expect(GuestCapabilities.dragDrop.rawValue == 1 << 3)
        #expect(GuestCapabilities.iconExtraction.rawValue == 1 << 4)
        #expect(GuestCapabilities.shortcutDetection.rawValue == 1 << 5)
        #expect(GuestCapabilities.highDpiSupport.rawValue == 1 << 6)
        #expect(GuestCapabilities.multiMonitor.rawValue == 1 << 7)
    }

    @Test("All core contains expected capabilities")
    func allCoreCapabilities() {
        let core = GuestCapabilities.allCore

        #expect(core.contains(.windowTracking))
        #expect(core.contains(.desktopDuplication))
        #expect(core.contains(.clipboardSync))
        #expect(core.contains(.iconExtraction))
    }

    @Test("Description lists enabled capabilities")
    func descriptionFormat() {
        let caps: GuestCapabilities = [.windowTracking, .clipboardSync]
        let desc = caps.description

        #expect(desc.contains("windowTracking"))
        #expect(desc.contains("clipboardSync"))
        #expect(!desc.contains("desktopDuplication"))
    }

    @Test("OptionSet operations work correctly")
    func optionSetOperations() {
        var caps: GuestCapabilities = [.windowTracking]
        caps.insert(.clipboardSync)

        #expect(caps.contains(.windowTracking))
        #expect(caps.contains(.clipboardSync))
        #expect(!caps.contains(.dragDrop))

        let combined = GuestCapabilities.windowTracking.union(.clipboardSync)
        #expect(combined == caps)
    }
}

// MARK: - Message Serialization Tests

@Suite("SpiceMessageSerializer")
struct SpiceMessageSerializerTests {
    @Test("Serialize launch program message")
    func serializeLaunchProgram() throws {
        let message = LaunchProgramSpiceMessage(
            messageId: 42,
            path: "C:\\Windows\\notepad.exe",
            arguments: ["/p", "test.txt"],
            workingDirectory: "C:\\Users\\Test"
        )

        let data = try SpiceMessageSerializer.serialize(message)

        // Check envelope format: [Type:1][Length:4][Payload:N]
        #expect(data.count >= 5)
        #expect(data[0] == SpiceMessageType.launchProgram.rawValue)

        // Read length bytes individually to avoid alignment issues
        let length = UInt32(data[1]) |
            (UInt32(data[2]) << 8) |
            (UInt32(data[3]) << 16) |
            (UInt32(data[4]) << 24)
        #expect(data.count == 5 + Int(length))
    }

    @Test("Serialize mouse input message")
    func serializeMouseInput() throws {
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

        #expect(data[0] == SpiceMessageType.mouseInput.rawValue)
    }

    @Test("Serialize keyboard input message")
    func serializeKeyboardInput() throws {
        let message = KeyboardInputSpiceMessage(
            messageId: 2,
            windowId: 12345,
            eventType: .keyDown,
            keyCode: 0x41,  // 'A'
            scanCode: 0x1E,
            modifiers: [.control, .shift]
        )

        let data = try SpiceMessageSerializer.serialize(message)

        #expect(data[0] == SpiceMessageType.keyboardInput.rawValue)
    }

    @Test("Serialize shutdown message")
    func serializeShutdown() throws {
        let message = ShutdownSpiceMessage(messageId: 99, timeoutMs: 10000)

        let data = try SpiceMessageSerializer.serialize(message)

        #expect(data[0] == SpiceMessageType.shutdown.rawValue)
    }

    @Test("Deserialize capability flags message")
    func deserializeCapabilityFlags() throws {
        let capabilities: GuestCapabilities = [.windowTracking, .clipboardSync]
        let original = CapabilityFlagsMessage(
            capabilities: capabilities,
            protocolVersion: SpiceProtocolVersion.combined,
            agentVersion: "1.0.0",
            osVersion: "Windows 11"
        )

        // Create envelope manually
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let payload = try encoder.encode(original)

        var envelope = Data()
        envelope.append(SpiceMessageType.capabilityFlags.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        let result = try SpiceMessageSerializer.deserialize(envelope)

        #expect(result != nil)
        #expect(result?.0 == .capabilityFlags)

        if let message = result?.1 as? CapabilityFlagsMessage {
            #expect(message.capabilities == capabilities)
            #expect(message.protocolVersion == SpiceProtocolVersion.combined)
            #expect(message.agentVersion == "1.0.0")
        } else {
            Issue.record("Expected CapabilityFlagsMessage")
        }
    }

    @Test("Try read message from incomplete buffer")
    func tryReadIncomplete() throws {
        // Only 3 bytes, need at least 5
        let buffer = Data([0x80, 0x00, 0x00])

        let result = try SpiceMessageSerializer.tryReadMessage(from: buffer)

        #expect(!result.isComplete)
        #expect(result.bytesConsumed == 0)
    }

    @Test("Try read message with incomplete payload")
    func tryReadIncompletePayload() throws {
        // Header says 100 bytes but only 5 total provided
        var buffer = Data()
        buffer.append(SpiceMessageType.heartbeat.rawValue)
        var length = UInt32(100).littleEndian
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }

        let result = try SpiceMessageSerializer.tryReadMessage(from: buffer)

        #expect(!result.isComplete)
        #expect(result.bytesConsumed == 0)
    }

    @Test("Deserialize returns nil for incomplete data")
    func deserializeIncomplete() throws {
        let result = try SpiceMessageSerializer.deserialize(Data([0x80, 0x00]))

        #expect(result == nil)
    }

    @Test("Invalid message type throws error")
    func invalidMessageType() {
        var buffer = Data()
        buffer.append(0x50)  // Invalid type not in enum
        var length = UInt32(0).littleEndian
        withUnsafeBytes(of: &length) { buffer.append(contentsOf: $0) }

        #expect(throws: SpiceProtocolError.self) {
            _ = try SpiceMessageSerializer.deserialize(buffer)
        }
    }
}

// MARK: - Version Negotiation Tests

@Suite("VersionNegotiationResult")
struct VersionNegotiationResultTests {
    @Test("Creates from capability message")
    func createFromCapabilityMessage() {
        let capabilities: GuestCapabilities = [.windowTracking, .desktopDuplication]
        let message = CapabilityFlagsMessage(
            capabilities: capabilities,
            protocolVersion: SpiceProtocolVersion.combined,
            agentVersion: "1.2.3",
            osVersion: "Windows 11 Pro"
        )

        let result = VersionNegotiationResult(from: message)

        #expect(result.isCompatible)
        #expect(result.hostVersion == SpiceProtocolVersion.combined)
        #expect(result.guestVersion == SpiceProtocolVersion.combined)
        #expect(result.guestCapabilities == capabilities)
        #expect(result.guestAgentVersion == "1.2.3")
        #expect(result.guestOsVersion == "Windows 11 Pro")
    }

    @Test("Detects incompatible version")
    func detectsIncompatibleVersion() {
        let message = CapabilityFlagsMessage(
            capabilities: .allCore,
            protocolVersion: (2 << 16) | 0,  // Version 2.0
            agentVersion: "2.0.0",
            osVersion: "Windows 12"
        )

        let result = VersionNegotiationResult(from: message)

        #expect(!result.isCompatible)
    }

    @Test("Description includes all fields")
    func descriptionFormat() {
        let message = CapabilityFlagsMessage(
            capabilities: [.windowTracking],
            protocolVersion: SpiceProtocolVersion.combined,
            agentVersion: "1.0.0",
            osVersion: "Windows 11"
        )

        let result = VersionNegotiationResult(from: message)
        let desc = result.description

        #expect(desc.contains("Version Negotiation"))
        #expect(desc.contains("Host:"))
        #expect(desc.contains("Guest:"))
        #expect(desc.contains("Compatible:"))
    }
}

// MARK: - RectInfo Tests

@Suite("RectInfo")
struct RectInfoTests {
    @Test("Initializes with correct values")
    func initialization() {
        let rect = RectInfo(x: 10, y: 20, width: 100, height: 200)

        #expect(rect.x == 10)
        #expect(rect.y == 20)
        #expect(rect.width == 100)
        #expect(rect.height == 200)
    }

    @Test("Codable round trip")
    func codableRoundTrip() throws {
        let original = RectInfo(x: -10, y: -20, width: 1920, height: 1080)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RectInfo.self, from: data)

        #expect(decoded == original)
    }

    @Test("Hashable for use in collections")
    func hashable() {
        let rect1 = RectInfo(x: 0, y: 0, width: 100, height: 100)
        let rect2 = RectInfo(x: 0, y: 0, width: 100, height: 100)
        let rect3 = RectInfo(x: 1, y: 0, width: 100, height: 100)

        #expect(rect1.hashValue == rect2.hashValue)
        #expect(rect1.hashValue != rect3.hashValue)

        var set: Set<RectInfo> = [rect1]
        set.insert(rect2)
        #expect(set.count == 1)

        set.insert(rect3)
        #expect(set.count == 2)
    }
}
