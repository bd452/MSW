import CoreGraphics
import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - Tests

final class SpiceWindowStreamTests: XCTestCase {
    private var transport: TestSpiceStreamTransport!
    private var delegate: TestSpiceWindowStreamDelegate!
    private var stream: SpiceWindowStream!
    private let testQueue = DispatchQueue(label: "test.delegate")

    override func setUp() {
        super.setUp()
        transport = TestSpiceStreamTransport()
        delegate = TestSpiceWindowStreamDelegate()
    }

    override func tearDown() {
        stream?.disconnect()
        stream = nil
        delegate = nil
        transport = nil
        super.tearDown()
    }

    private func makeStream(
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(maxAttempts: 3)
    ) -> SpiceWindowStream {
        let stream = SpiceWindowStream(
            configuration: SpiceStreamConfiguration.environmentDefault(),
            delegateQueue: testQueue,
            logger: NullLogger(),
            transport: transport,
            reconnectPolicy: reconnectPolicy
        )
        stream.delegate = delegate
        return stream
    }

    // MARK: - Connection Lifecycle Tests

    func testConnectTransitionsToConnectedState() {
        stream = makeStream()

        stream.connect(toWindowID: 42)

        // Allow async processing
        let expectation = expectation(description: "State change")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(stream.connectionState, .connected)
        XCTAssertEqual(transport.openCallCount, 1)
        XCTAssertEqual(transport.lastWindowID, 42)
        XCTAssertTrue(transport.isOpen)
    }

    func testConnectNotifiesDelegateOfStateChanges() {
        stream = makeStream()

        stream.connect(toWindowID: 1)

        let expectation = expectation(description: "Delegate notified")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertTrue(delegate.stateChanges.contains(.connecting))
        XCTAssertTrue(delegate.stateChanges.contains(.connected))
    }

    func testDuplicateConnectIsIgnored() {
        stream = makeStream()

        stream.connect(toWindowID: 1)
        stream.connect(toWindowID: 2)  // Should be ignored

        let expectation = expectation(description: "Processing")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(transport.openCallCount, 1)
        XCTAssertEqual(transport.lastWindowID, 1)
    }

    func testDisconnectClosesStream() {
        stream = makeStream()
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

        stream.disconnect()

        let disconnectExpectation = expectation(description: "Disconnected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            disconnectExpectation.fulfill()
        }
        wait(for: [disconnectExpectation], timeout: 1.0)

        XCTAssertEqual(stream.connectionState, .disconnected)
        XCTAssertEqual(transport.closeCallCount, 1)
        XCTAssertEqual(delegate.didCloseCallCount, 1)
    }

    // MARK: - Connection Failure Tests

    func testConnectionFailureTriggersReconnect() {
        transport.openBehavior = .fail(.connectionFailed("Test error"))
        let policy = ReconnectPolicy(initialDelay: 0.05, maxAttempts: 2)
        stream = makeStream(reconnectPolicy: policy)

        stream.connect(toWindowID: 1)

        // Wait for reconnect attempts
        let expectation = expectation(description: "Reconnect attempted")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Should have attempted to open twice (initial + 1 reconnect before hitting limit)
        XCTAssertGreaterThanOrEqual(transport.openCallCount, 2)
    }

    func testSharedMemoryUnavailableDoesNotReconnect() {
        transport.openBehavior = .fail(.sharedMemoryUnavailable("No vhost-user socket"))
        stream = makeStream()

        stream.connect(toWindowID: 1)

        let expectation = expectation(description: "Failed")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Should only attempt once - sharedMemoryUnavailable is a permanent failure
        XCTAssertEqual(transport.openCallCount, 1)

        if case .failed(let reason) = stream.connectionState {
            XCTAssertTrue(reason.contains("vhost-user"))
        } else {
            XCTFail("Expected failed state")
        }
    }

    func testManualReconnectResetsAttemptCounter() {
        stream = makeStream()
        transport.openBehavior = .fail(.connectionFailed("Error"))

        stream.connect(toWindowID: 1)

        // Wait for failure
        let failExpectation = expectation(description: "Failed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            failExpectation.fulfill()
        }
        wait(for: [failExpectation], timeout: 2.0)

        // Now make transport succeed and manually reconnect
        transport.openBehavior = .succeed
        transport.openCallCount = 0

        stream.reconnect()

        let reconnectExpectation = expectation(description: "Reconnected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            reconnectExpectation.fulfill()
        }
        wait(for: [reconnectExpectation], timeout: 1.0)

        XCTAssertEqual(stream.connectionState, .connected)
    }

    // MARK: - Pause/Resume Tests

    func testPauseSetsPausedFlag() {
        stream = makeStream()
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

        stream.pause()

        let pauseExpectation = expectation(description: "Paused")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            pauseExpectation.fulfill()
        }
        wait(for: [pauseExpectation], timeout: 1.0)

        XCTAssertTrue(stream.isPaused)
    }

    func testResumeClearsPausedFlag() {
        stream = makeStream()
        stream.connect(toWindowID: 1)
        stream.pause()

        let pauseExpectation = expectation(description: "Paused")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            pauseExpectation.fulfill()
        }
        wait(for: [pauseExpectation], timeout: 1.0)

        stream.resume()

        let resumeExpectation = expectation(description: "Resumed")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            resumeExpectation.fulfill()
        }
        wait(for: [resumeExpectation], timeout: 1.0)

        XCTAssertFalse(stream.isPaused)
    }
}

// MARK: - Input and Clipboard Tests

final class SpiceWindowStreamInputTests: XCTestCase {
    private var transport: TestSpiceStreamTransport!
    private var delegate: TestSpiceWindowStreamDelegate!
    private var stream: SpiceWindowStream!
    private let testQueue = DispatchQueue(label: "test.input")

    override func setUp() {
        super.setUp()
        transport = TestSpiceStreamTransport()
        delegate = TestSpiceWindowStreamDelegate()
    }

    override func tearDown() {
        stream?.disconnect()
        stream = nil
        delegate = nil
        transport = nil
        super.tearDown()
    }

    private func makeStream() -> SpiceWindowStream {
        let stream = SpiceWindowStream(
            configuration: SpiceStreamConfiguration.environmentDefault(),
            delegateQueue: testQueue,
            logger: NullLogger(),
            transport: transport,
            reconnectPolicy: ReconnectPolicy(maxAttempts: 3)
        )
        stream.delegate = delegate
        return stream
    }

    private func connectStream() {
        stream.connect(toWindowID: 1)
        let expectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Input Forwarding Tests

    func testMouseEventForwardedWhenConnected() {
        stream = makeStream()
        connectStream()

        let mouseEvent = MouseInputEvent(
            windowID: 1,
            eventType: .move,
            button: nil,
            x: 100,
            y: 200,
            scrollDeltaX: 0,
            scrollDeltaY: 0,
            modifiers: []
        )

        stream.sendMouseEvent(mouseEvent)

        let forwardExpectation = expectation(description: "Forwarded")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            forwardExpectation.fulfill()
        }
        wait(for: [forwardExpectation], timeout: 1.0)

        XCTAssertEqual(transport.mouseEvents.count, 1)
        XCTAssertEqual(transport.mouseEvents.first?.x, 100)
        XCTAssertEqual(transport.mouseEvents.first?.y, 200)
    }

    func testMouseEventDroppedWhenDisconnected() {
        stream = makeStream()
        // Don't connect

        let mouseEvent = MouseInputEvent(
            windowID: 1,
            eventType: .move,
            button: nil,
            x: 100,
            y: 200,
            scrollDeltaX: 0,
            scrollDeltaY: 0,
            modifiers: []
        )

        stream.sendMouseEvent(mouseEvent)

        let expectation = expectation(description: "Processing")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(transport.mouseEvents.count, 0)
    }

    func testKeyboardEventForwardedWhenConnected() {
        stream = makeStream()
        connectStream()

        let keyEvent = KeyboardInputEvent(
            windowID: 1,
            eventType: .down,
            keyCode: 0x00,  // 'A' key
            scanCode: 0x1E,
            isExtendedKey: false,
            modifiers: [],
            character: "a"
        )

        stream.sendKeyboardEvent(keyEvent)

        let forwardExpectation = expectation(description: "Forwarded")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            forwardExpectation.fulfill()
        }
        wait(for: [forwardExpectation], timeout: 1.0)

        XCTAssertEqual(transport.keyboardEvents.count, 1)
        XCTAssertEqual(transport.keyboardEvents.first?.character, "a")
    }

    // MARK: - Clipboard Tests

    func testClipboardSentWhenConnected() {
        stream = makeStream()
        connectStream()

        let clipboard = ClipboardData(
            format: .plainText,
            data: Data("Hello".utf8),
            sequenceNumber: 1
        )

        stream.sendClipboard(clipboard)

        let sendExpectation = expectation(description: "Sent")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            sendExpectation.fulfill()
        }
        wait(for: [sendExpectation], timeout: 1.0)

        XCTAssertEqual(transport.clipboardSent.count, 1)
        XCTAssertEqual(transport.clipboardSent.first?.format, .plainText)
    }

    func testClipboardRequestWhenConnected() {
        stream = makeStream()
        connectStream()

        stream.requestClipboard(format: .html)

        let requestExpectation = expectation(description: "Requested")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            requestExpectation.fulfill()
        }
        wait(for: [requestExpectation], timeout: 1.0)

        XCTAssertEqual(transport.clipboardRequests.count, 1)
        XCTAssertEqual(transport.clipboardRequests.first, .html)
    }
}

// MARK: - Delegate Callback and Metrics Tests

final class SpiceWindowStreamDelegateTests: XCTestCase {
    private var transport: TestSpiceStreamTransport!
    private var delegate: TestSpiceWindowStreamDelegate!
    private var stream: SpiceWindowStream!
    private let testQueue = DispatchQueue(label: "test.delegate.callbacks")

    override func setUp() {
        super.setUp()
        transport = TestSpiceStreamTransport()
        delegate = TestSpiceWindowStreamDelegate()
    }

    override func tearDown() {
        stream?.disconnect()
        stream = nil
        delegate = nil
        transport = nil
        super.tearDown()
    }

    private func makeStream() -> SpiceWindowStream {
        let stream = SpiceWindowStream(
            configuration: SpiceStreamConfiguration.environmentDefault(),
            delegateQueue: testQueue,
            logger: NullLogger(),
            transport: transport,
            reconnectPolicy: ReconnectPolicy(maxAttempts: 3)
        )
        stream.delegate = delegate
        return stream
    }

    private func connectStream() {
        stream.connect(toWindowID: 1)
        let expectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Delegate Callback Tests

    func testFrameDataDeliveredToDelegate() {
        stream = makeStream()
        connectStream()

        let frameData = Data([0x01, 0x02, 0x03, 0x04])
        transport.simulateFrame(frameData)

        let frameExpectation = expectation(description: "Frame received")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            frameExpectation.fulfill()
        }
        wait(for: [frameExpectation], timeout: 1.0)

        XCTAssertEqual(delegate.frames.count, 1)
        XCTAssertEqual(delegate.frames.first, frameData)
    }

    func testMetadataDeliveredToDelegate() {
        stream = makeStream()
        connectStream()

        let metadata = WindowMetadata(
            windowID: 1,
            title: "Test Window",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isResizable: true
        )
        transport.simulateMetadata(metadata)

        let metadataExpectation = expectation(description: "Metadata received")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            metadataExpectation.fulfill()
        }
        wait(for: [metadataExpectation], timeout: 1.0)

        XCTAssertEqual(delegate.metadataUpdates.count, 1)
        XCTAssertEqual(delegate.metadataUpdates.first?.title, "Test Window")
    }

    func testClipboardFromGuestDeliveredToDelegate() {
        stream = makeStream()
        connectStream()

        let clipboard = ClipboardData(
            format: .plainText,
            data: Data("From Windows".utf8),
            sequenceNumber: 5
        )
        transport.simulateClipboard(clipboard)

        let clipboardExpectation = expectation(description: "Clipboard received")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            clipboardExpectation.fulfill()
        }
        wait(for: [clipboardExpectation], timeout: 1.0)

        XCTAssertEqual(delegate.clipboardReceived.count, 1)
        XCTAssertEqual(delegate.clipboardReceived.first?.sequenceNumber, 5)
    }

    // MARK: - Metrics Tests

    func testMetricsTrackFramesReceived() {
        stream = makeStream()
        connectStream()

        transport.simulateFrame(Data([0x01]))
        transport.simulateFrame(Data([0x02]))
        transport.simulateFrame(Data([0x03]))

        let metricsExpectation = expectation(description: "Metrics updated")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            metricsExpectation.fulfill()
        }
        wait(for: [metricsExpectation], timeout: 1.0)

        let metrics = stream.metricsSnapshot()
        XCTAssertEqual(metrics.framesReceived, 3)
    }

    func testMetricsTrackMetadataUpdates() {
        stream = makeStream()
        connectStream()

        let metadata = WindowMetadata(
            windowID: 1,
            title: "Test",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isResizable: true
        )
        transport.simulateMetadata(metadata)
        transport.simulateMetadata(metadata)

        let metricsExpectation = expectation(description: "Metrics updated")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            metricsExpectation.fulfill()
        }
        wait(for: [metricsExpectation], timeout: 1.0)

        let metrics = stream.metricsSnapshot()
        XCTAssertEqual(metrics.metadataUpdates, 2)
    }
}
