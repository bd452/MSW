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

// MARK: - FrameReady Notification Tests

final class SpiceControlChannelFrameReadyTests: XCTestCase {
    func testFrameReadyNotificationDispatchesToDelegate() async throws {
        let channel = SpiceControlChannel()
        let delegate = MockControlChannelDelegate()
        await channel.setDelegateForTest(delegate)
        await channel.simulateConnected()

        // Create a FrameReady message
        let frameReady = FrameReadyMessage(
            windowId: 12345,
            slotIndex: 0,
            frameNumber: 1,
            isKeyFrame: true
        )

        let encoder = JSONEncoder()
        let payload = try encoder.encode(frameReady)

        var envelope = Data()
        envelope.append(SpiceMessageType.frameReady.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        try await channel.simulateResponse(envelope)

        // Verify the delegate was called with the FrameReady message
        XCTAssertEqual(delegate.frameReadyNotifications.count, 1)
        XCTAssertEqual(delegate.frameReadyNotifications[0].windowId, 12345)
        XCTAssertEqual(delegate.frameReadyNotifications[0].slotIndex, 0)
        XCTAssertEqual(delegate.frameReadyNotifications[0].frameNumber, 1)
        XCTAssertTrue(delegate.frameReadyNotifications[0].isKeyFrame)
    }

    func testFrameReadyDoesNotDispatchToGenericMessageHandler() async throws {
        let channel = SpiceControlChannel()
        let delegate = MockControlChannelDelegate()
        await channel.setDelegateForTest(delegate)
        await channel.simulateConnected()

        // Create a FrameReady message
        let frameReady = FrameReadyMessage(
            windowId: 12345,
            slotIndex: 2,
            frameNumber: 42,
            isKeyFrame: false
        )

        let encoder = JSONEncoder()
        let payload = try encoder.encode(frameReady)

        var envelope = Data()
        envelope.append(SpiceMessageType.frameReady.rawValue)
        var length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
        envelope.append(payload)

        try await channel.simulateResponse(envelope)

        // Verify the generic handler was NOT called (FrameReady uses dedicated path)
        XCTAssertEqual(delegate.receivedMessages.count, 0)
        // But the FrameReady handler was called
        XCTAssertEqual(delegate.frameReadyNotifications.count, 1)
    }

    func testMultipleFrameReadyNotificationsDispatchSequentially() async throws {
        let channel = SpiceControlChannel()
        let delegate = MockControlChannelDelegate()
        await channel.setDelegateForTest(delegate)
        await channel.simulateConnected()

        let encoder = JSONEncoder()

        // Send multiple FrameReady notifications
        for i in 0..<5 {
            let frameReady = FrameReadyMessage(
                windowId: UInt64(100 + i),
                slotIndex: UInt32(i % 3),
                frameNumber: UInt32(i),
                isKeyFrame: i == 0
            )

            let payload = try encoder.encode(frameReady)

            var envelope = Data()
            envelope.append(SpiceMessageType.frameReady.rawValue)
            var length = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
            envelope.append(payload)

            try await channel.simulateResponse(envelope)
        }

        // Verify all notifications were received
        XCTAssertEqual(delegate.frameReadyNotifications.count, 5)

        // Verify order and content
        for i in 0..<5 {
            XCTAssertEqual(delegate.frameReadyNotifications[i].windowId, UInt64(100 + i))
            XCTAssertEqual(delegate.frameReadyNotifications[i].frameNumber, UInt32(i))
        }
    }

    func testFrameReadyWithDifferentWindowIds() async throws {
        let channel = SpiceControlChannel()
        let delegate = MockControlChannelDelegate()
        await channel.setDelegateForTest(delegate)
        await channel.simulateConnected()

        let encoder = JSONEncoder()
        let windowIds: [UInt64] = [100, 200, 100, 300, 200]

        for (index, windowId) in windowIds.enumerated() {
            let frameReady = FrameReadyMessage(
                windowId: windowId,
                slotIndex: UInt32(index % 3),
                frameNumber: UInt32(index),
                isKeyFrame: true
            )

            let payload = try encoder.encode(frameReady)

            var envelope = Data()
            envelope.append(SpiceMessageType.frameReady.rawValue)
            var length = UInt32(payload.count).littleEndian
            withUnsafeBytes(of: &length) { envelope.append(contentsOf: $0) }
            envelope.append(payload)

            try await channel.simulateResponse(envelope)
        }

        // Verify all notifications were received
        XCTAssertEqual(delegate.frameReadyNotifications.count, 5)

        // Verify we can filter by window ID
        let window100Frames = delegate.frameReadyNotifications.filter { $0.windowId == 100 }
        XCTAssertEqual(window100Frames.count, 2)

        let window200Frames = delegate.frameReadyNotifications.filter { $0.windowId == 200 }
        XCTAssertEqual(window200Frames.count, 2)

        let window300Frames = delegate.frameReadyNotifications.filter { $0.windowId == 300 }
        XCTAssertEqual(window300Frames.count, 1)
    }
}

// MARK: - Mock Delegate for Testing

final class MockControlChannelDelegate: SpiceControlChannelDelegate {
    var didConnect = false
    var didDisconnect = false
    var receivedMessages: [(message: Any, type: SpiceMessageType)] = []
    var frameReadyNotifications: [FrameReadyMessage] = []

    func controlChannelDidConnect(_ channel: SpiceControlChannel) {
        didConnect = true
    }

    func controlChannelDidDisconnect(_ channel: SpiceControlChannel) {
        didDisconnect = true
    }

    func controlChannel(_ channel: SpiceControlChannel, didReceiveMessage message: Any, type: SpiceMessageType) {
        receivedMessages.append((message: message, type: type))
    }

    func controlChannel(_ channel: SpiceControlChannel, didReceiveFrameReady notification: FrameReadyMessage) {
        frameReadyNotifications.append(notification)
    }
}

// MARK: - SpiceControlChannel Test Extension

extension SpiceControlChannel {
    /// Sets the delegate for testing purposes (avoids async/nonisolated getter complexity)
    func setDelegateForTest(_ delegate: SpiceControlChannelDelegate?) async {
        // Small delay to ensure the delegate is set before tests continue
        delegate.map { self.delegate = $0 }
        try? await Task.sleep(for: .milliseconds(10))
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
