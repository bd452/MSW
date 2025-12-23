import Foundation
import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - Provisioning Message Tests

final class ProvisioningMessageTests: XCTestCase {
    func testGuestProvisioningPhaseDisplayNames() {
        XCTAssertEqual(GuestProvisioningPhase.drivers.displayName, "Installing drivers")
        XCTAssertEqual(GuestProvisioningPhase.agent.displayName, "Installing WinRun Agent")
        XCTAssertEqual(GuestProvisioningPhase.optimize.displayName, "Optimizing Windows")
        XCTAssertEqual(GuestProvisioningPhase.finalize.displayName, "Finalizing")
        XCTAssertEqual(GuestProvisioningPhase.complete.displayName, "Complete")
    }

    func testProvisionProgressMessageInitialization() {
        let message = ProvisionProgressMessage(
            phase: .drivers,
            percent: 50,
            message: "Installing VirtIO drivers"
        )

        XCTAssertEqual(message.phase, .drivers)
        XCTAssertEqual(message.percent, 50)
        XCTAssertEqual(message.message, "Installing VirtIO drivers")
    }

    func testProvisionProgressMessageClampsPercent() {
        let message = ProvisionProgressMessage(
            phase: .agent,
            percent: 150,
            message: "Test"
        )

        XCTAssertEqual(message.percent, 100)
    }

    func testProvisionProgressFraction() {
        let message = ProvisionProgressMessage(
            phase: .optimize,
            percent: 75,
            message: "Optimizing"
        )

        XCTAssertEqual(message.progressFraction, 0.75, accuracy: 0.001)
    }

    func testProvisionErrorMessageInitialization() {
        let message = ProvisionErrorMessage(
            phase: .drivers,
            errorCode: 0x8007_0005,
            message: "Access denied",
            isRecoverable: true
        )

        XCTAssertEqual(message.phase, .drivers)
        XCTAssertEqual(message.errorCode, 0x8007_0005)
        XCTAssertEqual(message.message, "Access denied")
        XCTAssertTrue(message.isRecoverable)
    }

    func testProvisionErrorMessageDefaultsToNonRecoverable() {
        let message = ProvisionErrorMessage(
            phase: .optimize,
            errorCode: 1,
            message: "Error"
        )

        XCTAssertFalse(message.isRecoverable)
    }

    func testProvisionCompleteMessageSuccess() {
        let message = ProvisionCompleteMessage(
            success: true,
            diskUsageMB: 12345,
            windowsVersion: "Windows 11 Pro 23H2",
            agentVersion: "1.2.3"
        )

        XCTAssertTrue(message.success)
        XCTAssertEqual(message.diskUsageMB, 12345)
        XCTAssertEqual(message.windowsVersion, "Windows 11 Pro 23H2")
        XCTAssertEqual(message.agentVersion, "1.2.3")
        XCTAssertNil(message.errorMessage)
    }

    func testProvisionCompleteMessageFailure() {
        let message = ProvisionCompleteMessage(
            success: false,
            diskUsageMB: 0,
            windowsVersion: "Windows 11",
            agentVersion: "Unknown",
            errorMessage: "Installation failed"
        )

        XCTAssertFalse(message.success)
        XCTAssertEqual(message.errorMessage, "Installation failed")
    }

    func testProvisionCompleteMessageDiskUsageBytes() {
        let message = ProvisionCompleteMessage(
            success: true,
            diskUsageMB: 1024,
            windowsVersion: "Windows 11",
            agentVersion: "1.0.0"
        )

        XCTAssertEqual(message.diskUsageBytes, 1024 * 1024 * 1024)
    }

    func testProvisionProgressMessageCodable() throws {
        let original = ProvisionProgressMessage(
            phase: .agent,
            percent: 80,
            message: "Registering service"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ProvisionProgressMessage.self, from: data)

        XCTAssertEqual(decoded.phase, original.phase)
        XCTAssertEqual(decoded.percent, original.percent)
        XCTAssertEqual(decoded.message, original.message)
    }

    func testProvisionErrorMessageCodable() throws {
        let original = ProvisionErrorMessage(
            phase: .optimize,
            errorCode: 0x8007_0002,
            message: "File not found",
            isRecoverable: true
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ProvisionErrorMessage.self, from: data)

        XCTAssertEqual(decoded.phase, original.phase)
        XCTAssertEqual(decoded.errorCode, original.errorCode)
        XCTAssertEqual(decoded.message, original.message)
        XCTAssertEqual(decoded.isRecoverable, original.isRecoverable)
    }

    func testProvisionCompleteMessageCodable() throws {
        let original = ProvisionCompleteMessage(
            success: true,
            diskUsageMB: 8192,
            windowsVersion: "Windows 11 IoT Enterprise LTSC",
            agentVersion: "1.0.0",
            errorMessage: nil
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ProvisionCompleteMessage.self, from: data)

        XCTAssertEqual(decoded.success, original.success)
        XCTAssertEqual(decoded.diskUsageMB, original.diskUsageMB)
        XCTAssertEqual(decoded.windowsVersion, original.windowsVersion)
        XCTAssertEqual(decoded.agentVersion, original.agentVersion)
        XCTAssertNil(decoded.errorMessage)
    }

    func testDeserializeProvisionProgressFromGuestFormat() throws {
        // Simulate message from guest using camelCase JSON
        let json = """
            {
                "timestamp": 1700000000000,
                "phase": "drivers",
                "percent": 50,
                "message": "Installing VirtIO drivers"
            }
            """
        let payload = json.data(using: .utf8)!

        var envelope = Data()
        envelope.append(SpiceMessageType.provisionProgress.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        let result = try SpiceMessageSerializer.deserialize(envelope)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, .provisionProgress)

        if let message = result?.1 as? ProvisionProgressMessage {
            XCTAssertEqual(message.phase, .drivers)
            XCTAssertEqual(message.percent, 50)
            XCTAssertEqual(message.message, "Installing VirtIO drivers")
        } else {
            XCTFail("Expected ProvisionProgressMessage")
        }
    }

    func testDeserializeProvisionErrorFromGuestFormat() throws {
        let json = """
            {
                "timestamp": 1700000000000,
                "phase": "optimize",
                "errorCode": 2147942405,
                "message": "Access denied",
                "isRecoverable": true
            }
            """
        let payload = json.data(using: .utf8)!

        var envelope = Data()
        envelope.append(SpiceMessageType.provisionError.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        let result = try SpiceMessageSerializer.deserialize(envelope)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, .provisionError)

        if let message = result?.1 as? ProvisionErrorMessage {
            XCTAssertEqual(message.phase, .optimize)
            XCTAssertEqual(message.errorCode, 0x8007_0005)
            XCTAssertEqual(message.message, "Access denied")
            XCTAssertTrue(message.isRecoverable)
        } else {
            XCTFail("Expected ProvisionErrorMessage")
        }
    }

    func testDeserializeProvisionCompleteFromGuestFormat() throws {
        let json = """
            {
                "timestamp": 1700000000000,
                "success": true,
                "diskUsageMB": 8192,
                "windowsVersion": "Windows 11 IoT Enterprise LTSC",
                "agentVersion": "1.0.0"
            }
            """
        let payload = json.data(using: .utf8)!

        var envelope = Data()
        envelope.append(SpiceMessageType.provisionComplete.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        let result = try SpiceMessageSerializer.deserialize(envelope)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0, .provisionComplete)

        if let message = result?.1 as? ProvisionCompleteMessage {
            XCTAssertTrue(message.success)
            XCTAssertEqual(message.diskUsageMB, 8192)
            XCTAssertEqual(message.windowsVersion, "Windows 11 IoT Enterprise LTSC")
            XCTAssertEqual(message.agentVersion, "1.0.0")
        } else {
            XCTFail("Expected ProvisionCompleteMessage")
        }
    }
}
