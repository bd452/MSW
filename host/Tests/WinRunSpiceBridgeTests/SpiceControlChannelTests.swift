import Foundation
import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - SpiceControlChannel Tests

final class SpiceControlChannelTests: XCTestCase {

    // MARK: - Close Session Tests

    func testCloseSessionSerializesCorrectMessage() async throws {
        let channel = SpiceControlChannel()

        // Simulate connected state
        await channel.simulateConnected()

        // Start the closeSession call, but simulate response before it times out
        let closeTask = Task {
            try await channel.closeSession("12345", timeout: .milliseconds(500))
        }

        // Give the task time to start and register the pending request
        try await Task.sleep(for: .milliseconds(50))

        // Simulate a successful ACK response
        let ack = AckMessage(messageId: 1, success: true, errorMessage: nil)
        let encoder = JSONEncoder()
        let payload = try encoder.encode(ack)

        var envelope = Data()
        envelope.append(SpiceMessageType.ack.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        try await channel.simulateResponse(envelope)

        // Verify no error was thrown
        try await closeTask.value
    }

    func testCloseSessionHandlesFailureAck() async throws {
        let channel = SpiceControlChannel()
        await channel.simulateConnected()

        let closeTask = Task {
            try await channel.closeSession("99999", timeout: .milliseconds(500))
        }

        try await Task.sleep(for: .milliseconds(50))

        // Simulate a failure ACK response
        let ack = AckMessage(messageId: 1, success: false, errorMessage: "Session not found")
        let encoder = JSONEncoder()
        let payload = try encoder.encode(ack)

        var envelope = Data()
        envelope.append(SpiceMessageType.ack.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        try await channel.simulateResponse(envelope)

        // Verify error was thrown
        do {
            try await closeTask.value
            XCTFail("Expected SpiceControlError.guestError")
        } catch let error as SpiceControlError {
            if case .guestError(let code, let message) = error {
                XCTAssertEqual(code, "CLOSE_SESSION_FAILED")
                XCTAssertEqual(message, "Session not found")
            } else {
                XCTFail("Expected guestError, got \(error)")
            }
        }
    }

    func testCloseSessionFailsWhenNotConnected() async throws {
        let channel = SpiceControlChannel()

        // Don't call simulateConnected() - channel should be disconnected

        do {
            try await channel.closeSession("12345", timeout: .milliseconds(100))
            XCTFail("Expected SpiceControlError.notConnected")
        } catch let error as SpiceControlError {
            if case .notConnected = error {
                // Expected
            } else {
                XCTFail("Expected notConnected, got \(error)")
            }
        }
    }

    func testCloseSessionTimesOut() async throws {
        let channel = SpiceControlChannel()
        await channel.simulateConnected()

        // Call closeSession with very short timeout, don't simulate response
        do {
            try await channel.closeSession("12345", timeout: .milliseconds(50))
            XCTFail("Expected SpiceControlError.timeout")
        } catch let error as SpiceControlError {
            if case .timeout = error {
                // Expected
            } else {
                XCTFail("Expected timeout, got \(error)")
            }
        }
    }

    // MARK: - Connection State Tests

    func testConnectedPropertyInitiallyFalse() async {
        let channel = SpiceControlChannel()
        let connected = await channel.connected
        XCTAssertFalse(connected)
    }

    func testConnectedPropertyAfterConnect() async throws {
        let channel = SpiceControlChannel()
        try await channel.connect()
        let connected = await channel.connected
        XCTAssertTrue(connected)
    }

    func testDisconnectSetsConnectedFalse() async throws {
        let channel = SpiceControlChannel()
        try await channel.connect()
        await channel.disconnect()
        let connected = await channel.connected
        XCTAssertFalse(connected)
    }

    // MARK: - List Sessions Tests

    func testListSessionsReturnsSessionList() async throws {
        let channel = SpiceControlChannel()
        await channel.simulateConnected()

        let listTask = Task {
            try await channel.listSessions(timeout: .milliseconds(500))
        }

        try await Task.sleep(for: .milliseconds(50))

        // Create a session list response
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

        let sessionList = SessionListMessage(
            messageId: 1,
            sessions: [sessionInfo]
        )

        let encoder = JSONEncoder()
        let payload = try encoder.encode(sessionList)

        var envelope = Data()
        envelope.append(SpiceMessageType.sessionList.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        try await channel.simulateResponse(envelope)

        let result = try await listTask.value

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].id, "1234")
        XCTAssertEqual(result.sessions[0].windowsPath, "C:\\Windows\\notepad.exe")
    }

    func testListSessionsFailsWhenNotConnected() async {
        let channel = SpiceControlChannel()

        do {
            _ = try await channel.listSessions(timeout: .milliseconds(100))
            XCTFail("Expected SpiceControlError.notConnected")
        } catch let error as SpiceControlError {
            if case .notConnected = error {
                // Expected
            } else {
                XCTFail("Expected notConnected, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - SpiceControlError Tests

final class SpiceControlErrorTests: XCTestCase {
    func testErrorDescriptions() {
        XCTAssertEqual(
            SpiceControlError.notConnected.description,
            "Control channel not connected"
        )

        XCTAssertEqual(
            SpiceControlError.timeout.description,
            "Request timed out"
        )

        let guestError = SpiceControlError.guestError(code: "TEST_ERROR", message: "Test message")
        XCTAssertTrue(guestError.description.contains("TEST_ERROR"))
        XCTAssertTrue(guestError.description.contains("Test message"))
    }

    func testProtocolErrorWrapping() {
        let protocolError = SpiceProtocolError.unknownMessageType
        let controlError = SpiceControlError.protocolError(protocolError)

        XCTAssertTrue(controlError.description.contains("Protocol error"))
    }

    func testSendFailedWrapping() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "Test send failure" }
        }

        let sendError = SpiceControlError.sendFailed(TestError())
        XCTAssertTrue(sendError.description.contains("Failed to send"))
    }
}
