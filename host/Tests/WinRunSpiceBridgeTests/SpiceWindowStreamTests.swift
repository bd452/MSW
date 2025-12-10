import CoreGraphics
import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - Test Transport

/// A controllable mock transport for testing SpiceWindowStream.
final class TestSpiceStreamTransport: SpiceStreamTransport {
    indirect enum OpenBehavior {
        case succeed
        case fail(SpiceStreamError)
        case delay(TimeInterval, then: OpenBehavior)
    }

    var openBehavior: OpenBehavior = .succeed
    var isOpen = false
    var openCallCount = 0
    var closeCallCount = 0
    var lastWindowID: UInt64?
    var lastConfiguration: SpiceStreamConfiguration?

    // Input tracking
    var mouseEvents: [MouseInputEvent] = []
    var keyboardEvents: [KeyboardInputEvent] = []
    var clipboardSent: [ClipboardData] = []
    var clipboardRequests: [ClipboardFormat] = []
    var dragDropEvents: [DragDropEvent] = []

    // Callback storage for triggering events from tests
    private var callbacks: SpiceStreamCallbacks?

    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription {
        openCallCount += 1
        lastWindowID = windowID
        lastConfiguration = configuration
        self.callbacks = callbacks

        switch openBehavior {
        case .succeed:
            isOpen = true
            return SpiceStreamSubscription { [weak self] in
                self?.isOpen = false
            }
        case .fail(let error):
            throw error
        case .delay(let interval, let thenBehavior):
            // For testing async behavior
            Thread.sleep(forTimeInterval: interval)
            openBehavior = thenBehavior
            return try openStream(
                configuration: configuration, windowID: windowID, callbacks: callbacks)
        }
    }

    func closeStream(_ subscription: SpiceStreamSubscription) {
        closeCallCount += 1
        isOpen = false
        callbacks = nil
        subscription.cleanup()
    }

    func sendMouseEvent(_ event: MouseInputEvent) {
        mouseEvents.append(event)
    }

    func sendKeyboardEvent(_ event: KeyboardInputEvent) {
        keyboardEvents.append(event)
    }

    func sendClipboard(_ clipboard: ClipboardData) {
        clipboardSent.append(clipboard)
    }

    func requestClipboard(format: ClipboardFormat) {
        clipboardRequests.append(format)
    }

    func sendDragDropEvent(_ event: DragDropEvent) {
        dragDropEvents.append(event)
    }

    // Test helpers to simulate events from guest

    func simulateFrame(_ data: Data) {
        callbacks?.onFrame(data)
    }

    func simulateMetadata(_ metadata: WindowMetadata) {
        callbacks?.onMetadata(metadata)
    }

    func simulateClose(_ reason: SpiceStreamCloseReason) {
        callbacks?.onClosed(reason)
    }

    func simulateClipboard(_ clipboard: ClipboardData) {
        callbacks?.onClipboard(clipboard)
    }

    func reset() {
        openBehavior = .succeed
        isOpen = false
        openCallCount = 0
        closeCallCount = 0
        lastWindowID = nil
        lastConfiguration = nil
        mouseEvents.removeAll()
        keyboardEvents.removeAll()
        clipboardSent.removeAll()
        clipboardRequests.removeAll()
        dragDropEvents.removeAll()
        callbacks = nil
    }
}

// MARK: - Test Delegate

final class TestSpiceWindowStreamDelegate: SpiceWindowStreamDelegate {
    var frames: [Data] = []
    var metadataUpdates: [WindowMetadata] = []
    var stateChanges: [SpiceConnectionState] = []
    var clipboardReceived: [ClipboardData] = []
    var didCloseCallCount = 0

    private let stateExpectation: XCTestExpectation?
    private let targetState: SpiceConnectionState?

    init(expectState: SpiceConnectionState? = nil, expectation: XCTestExpectation? = nil) {
        self.targetState = expectState
        self.stateExpectation = expectation
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateFrame frame: Data) {
        frames.append(frame)
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateMetadata metadata: WindowMetadata) {
        metadataUpdates.append(metadata)
    }

    func windowStream(_ stream: SpiceWindowStream, didChangeState state: SpiceConnectionState) {
        stateChanges.append(state)
        if let target = targetState, state == target {
            stateExpectation?.fulfill()
        }
    }

    func windowStreamDidClose(_ stream: SpiceWindowStream) {
        didCloseCallCount += 1
    }

    func windowStream(_ stream: SpiceWindowStream, didReceiveClipboard clipboard: ClipboardData) {
        clipboardReceived.append(clipboard)
    }

    func reset() {
        frames.removeAll()
        metadataUpdates.removeAll()
        stateChanges.removeAll()
        clipboardReceived.removeAll()
        didCloseCallCount = 0
    }
}

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
        stream = makeStream(
            reconnectPolicy: ReconnectPolicy(
                initialDelay: 0.05,
                maxAttempts: 2
            ))

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

    // MARK: - Input Forwarding Tests

    func testMouseEventForwardedWhenConnected() {
        stream = makeStream()
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

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
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

        let keyEvent = KeyboardInputEvent(
            windowID: 1,
            eventType: .keyDown,
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
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

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
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

        stream.requestClipboard(format: .html)

        let requestExpectation = expectation(description: "Requested")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            requestExpectation.fulfill()
        }
        wait(for: [requestExpectation], timeout: 1.0)

        XCTAssertEqual(transport.clipboardRequests.count, 1)
        XCTAssertEqual(transport.clipboardRequests.first, .html)
    }

    // MARK: - Delegate Callback Tests

    func testFrameDataDeliveredToDelegate() {
        stream = makeStream()
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

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
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

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
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

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
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

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
        stream.connect(toWindowID: 1)

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

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

    // MARK: - Connection State Tests

    func testConnectionStateEquatableConformance() {
        XCTAssertEqual(SpiceConnectionState.connected, SpiceConnectionState.connected)
        XCTAssertEqual(SpiceConnectionState.disconnected, SpiceConnectionState.disconnected)
        XCTAssertNotEqual(SpiceConnectionState.connected, SpiceConnectionState.disconnected)

        XCTAssertEqual(
            SpiceConnectionState.reconnecting(attempt: 1, maxAttempts: 3),
            SpiceConnectionState.reconnecting(attempt: 1, maxAttempts: 3)
        )
        XCTAssertNotEqual(
            SpiceConnectionState.reconnecting(attempt: 1, maxAttempts: 3),
            SpiceConnectionState.reconnecting(attempt: 2, maxAttempts: 3)
        )

        XCTAssertEqual(
            SpiceConnectionState.failed(reason: "error"),
            SpiceConnectionState.failed(reason: "error")
        )
    }

    func testConnectionStateDescription() {
        XCTAssertEqual(SpiceConnectionState.disconnected.description, "Disconnected")
        XCTAssertEqual(SpiceConnectionState.connecting.description, "Connecting...")
        XCTAssertEqual(SpiceConnectionState.connected.description, "Connected")
        XCTAssertEqual(
            SpiceConnectionState.reconnecting(attempt: 2, maxAttempts: 5).description,
            "Reconnecting (2/5)..."
        )
        XCTAssertEqual(
            SpiceConnectionState.reconnecting(attempt: 3, maxAttempts: nil).description,
            "Reconnecting (attempt 3)..."
        )
        XCTAssertTrue(
            SpiceConnectionState.failed(reason: "timeout").description.contains("timeout"))
    }

    func testConnectionStateIsConnected() {
        XCTAssertTrue(SpiceConnectionState.connected.isConnected)
        XCTAssertFalse(SpiceConnectionState.connecting.isConnected)
        XCTAssertFalse(SpiceConnectionState.disconnected.isConnected)
        XCTAssertFalse(SpiceConnectionState.reconnecting(attempt: 1, maxAttempts: 3).isConnected)
        XCTAssertFalse(SpiceConnectionState.failed(reason: "error").isConnected)
    }

    func testConnectionStateIsTransitioning() {
        XCTAssertTrue(SpiceConnectionState.connecting.isTransitioning)
        XCTAssertTrue(SpiceConnectionState.reconnecting(attempt: 1, maxAttempts: 3).isTransitioning)
        XCTAssertFalse(SpiceConnectionState.connected.isTransitioning)
        XCTAssertFalse(SpiceConnectionState.disconnected.isTransitioning)
        XCTAssertFalse(SpiceConnectionState.failed(reason: "error").isTransitioning)
    }
}

// MARK: - ReconnectPolicy Tests

final class ReconnectPolicyTests: XCTestCase {
    func testDefaultPolicyValues() {
        let policy = ReconnectPolicy()

        XCTAssertEqual(policy.initialDelay, 0.5)
        XCTAssertEqual(policy.multiplier, 1.8)
        XCTAssertEqual(policy.maxDelay, 15)
        XCTAssertEqual(policy.maxAttempts, 5)
    }

    func testDelayCalculationWithExponentialBackoff() {
        let policy = ReconnectPolicy(
            initialDelay: 1.0,
            multiplier: 2.0,
            maxDelay: 30.0
        )

        XCTAssertEqual(policy.delay(for: 1), 1.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: 2), 2.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: 3), 4.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: 4), 8.0, accuracy: 0.01)
    }

    func testDelayDoesNotExceedMaxDelay() {
        let policy = ReconnectPolicy(
            initialDelay: 1.0,
            multiplier: 10.0,
            maxDelay: 5.0
        )

        XCTAssertEqual(policy.delay(for: 1), 1.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: 2), 5.0, accuracy: 0.01)  // Would be 10, capped to 5
        XCTAssertEqual(policy.delay(for: 3), 5.0, accuracy: 0.01)  // Would be 100, capped to 5
    }

    func testDelayForZeroOrNegativeAttemptTreatedAsFirst() {
        let policy = ReconnectPolicy(initialDelay: 2.0, multiplier: 2.0)

        XCTAssertEqual(policy.delay(for: 0), 2.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: -1), 2.0, accuracy: 0.01)
    }
}

// MARK: - WindowMetadata Tests

final class WindowMetadataTests: XCTestCase {
    func testWindowMetadataInitialization() {
        let metadata = WindowMetadata(
            windowID: 123,
            title: "Test Window",
            frame: CGRect(x: 100, y: 200, width: 800, height: 600),
            isResizable: true,
            scaleFactor: 2.0
        )

        XCTAssertEqual(metadata.windowID, 123)
        XCTAssertEqual(metadata.title, "Test Window")
        XCTAssertEqual(metadata.frame.origin.x, 100)
        XCTAssertEqual(metadata.frame.origin.y, 200)
        XCTAssertEqual(metadata.frame.size.width, 800)
        XCTAssertEqual(metadata.frame.size.height, 600)
        XCTAssertTrue(metadata.isResizable)
        XCTAssertEqual(metadata.scaleFactor, 2.0)
    }

    func testWindowMetadataDefaultScaleFactor() {
        let metadata = WindowMetadata(
            windowID: 1,
            title: "Test",
            frame: .zero,
            isResizable: false
        )

        XCTAssertEqual(metadata.scaleFactor, 1.0)
    }

    func testWindowMetadataHashable() {
        let metadata1 = WindowMetadata(
            windowID: 1,
            title: "Window",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isResizable: true
        )
        let metadata2 = WindowMetadata(
            windowID: 1,
            title: "Window",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            isResizable: true
        )

        XCTAssertEqual(metadata1, metadata2)
        XCTAssertEqual(metadata1.hashValue, metadata2.hashValue)
    }

    func testWindowMetadataCodable() throws {
        let original = WindowMetadata(
            windowID: 42,
            title: "Codable Test",
            frame: CGRect(x: 10, y: 20, width: 300, height: 400),
            isResizable: false,
            scaleFactor: 1.5
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WindowMetadata.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}

// MARK: - NullLogger

/// A logger that discards all messages (for use in tests).
private struct NullLogger: Logger {
    func log(
        level: LogLevel, message: String, metadata: LogMetadata?, file: String, function: String,
        line: UInt
    ) {
        // Intentionally empty - discard all log messages
    }
}
