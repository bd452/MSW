import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - SpiceFrameRouter Tests

final class SpiceFrameRouterTests: XCTestCase {
    private var router: SpiceFrameRouter!
    private var transport: TestSpiceStreamTransport!
    private let testQueue = DispatchQueue(label: "test.frame-router")

    override func setUp() {
        super.setUp()
        router = SpiceFrameRouter(logger: NullLogger())
        transport = TestSpiceStreamTransport()
    }

    override func tearDown() {
        router = nil
        transport = nil
        super.tearDown()
    }

    private func makeStream(windowID: UInt64) -> (SpiceWindowStream, TestSpiceWindowStreamDelegate) {
        let delegate = TestSpiceWindowStreamDelegate()
        let stream = SpiceWindowStream(
            configuration: SpiceStreamConfiguration.environmentDefault(),
            delegateQueue: testQueue,
            logger: NullLogger(),
            transport: transport,
            reconnectPolicy: ReconnectPolicy(maxAttempts: 1)
        )
        stream.delegate = delegate
        stream.connect(toWindowID: windowID)

        // Wait for connection
        let expectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        return (stream, delegate)
    }

    // MARK: - Registration Tests

    func testRegisterStreamIncreasesCount() {
        let (stream, _) = makeStream(windowID: 100)
        router.registerStream(stream, forWindowID: 100)

        let expectation = expectation(description: "Registration")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(router.registeredStreamCount, 1)
    }

    func testUnregisterStreamDecreasesCount() {
        let (stream, _) = makeStream(windowID: 100)
        router.registerStream(stream, forWindowID: 100)

        let registerExpectation = expectation(description: "Registration")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            registerExpectation.fulfill()
        }
        wait(for: [registerExpectation], timeout: 1.0)

        router.unregisterStream(forWindowID: 100)

        let unregisterExpectation = expectation(description: "Unregistration")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            unregisterExpectation.fulfill()
        }
        wait(for: [unregisterExpectation], timeout: 1.0)

        XCTAssertEqual(router.registeredStreamCount, 0)
    }

    func testUnregisterAllStreamsClearsRegistry() {
        let (stream1, _) = makeStream(windowID: 100)
        let (stream2, _) = makeStream(windowID: 200)
        router.registerStream(stream1, forWindowID: 100)
        router.registerStream(stream2, forWindowID: 200)

        let registerExpectation = expectation(description: "Registration")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            registerExpectation.fulfill()
        }
        wait(for: [registerExpectation], timeout: 1.0)

        XCTAssertEqual(router.registeredStreamCount, 2)

        router.unregisterAllStreams()

        let unregisterExpectation = expectation(description: "Unregistration")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            unregisterExpectation.fulfill()
        }
        wait(for: [unregisterExpectation], timeout: 1.0)

        XCTAssertEqual(router.registeredStreamCount, 0)
    }

    // MARK: - Routing Tests

    func testFrameReadyRoutedToCorrectStream() {
        let (stream1, delegate1) = makeStream(windowID: 100)
        let (stream2, delegate2) = makeStream(windowID: 200)

        // Create a mock shared frame buffer with test data
        let bufferConfig = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let bufferPointer = createTestFrameBuffer(config: bufferConfig, windowID: 100, frameNumber: 1)
        let reader = SharedFrameBufferReader(
            pointer: bufferPointer,
            size: bufferConfig.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        router.setFrameBufferReader(reader)
        router.registerStream(stream1, forWindowID: 100)
        router.registerStream(stream2, forWindowID: 200)

        let setupExpectation = expectation(description: "Setup")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            setupExpectation.fulfill()
        }
        wait(for: [setupExpectation], timeout: 1.0)

        // Route a FrameReady notification for window 100
        let notification = FrameReadyMessage(
            windowId: 100,
            slotIndex: 0,
            frameNumber: 1,
            isKeyFrame: true
        )
        router.routeFrameReady(notification)

        let routeExpectation = expectation(description: "Routed")
        testQueue.asyncAfter(deadline: .now() + 0.2) {
            routeExpectation.fulfill()
        }
        wait(for: [routeExpectation], timeout: 1.0)

        // Stream 1 should have received the frame
        XCTAssertEqual(delegate1.sharedFrames.count, 1)
        XCTAssertEqual(delegate1.sharedFrames.first?.windowId, 100)
        XCTAssertEqual(delegate1.sharedFrames.first?.frameNumber, 1)

        // Stream 2 should not have received any frames
        XCTAssertEqual(delegate2.sharedFrames.count, 0)
    }

    func testFrameReadyForUnknownWindowIsDropped() {
        let (stream1, delegate1) = makeStream(windowID: 100)
        router.registerStream(stream1, forWindowID: 100)

        let setupExpectation = expectation(description: "Setup")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            setupExpectation.fulfill()
        }
        wait(for: [setupExpectation], timeout: 1.0)

        // Route a FrameReady notification for an unknown window
        let notification = FrameReadyMessage(
            windowId: 999,
            slotIndex: 0,
            frameNumber: 1,
            isKeyFrame: true
        )
        router.routeFrameReady(notification)

        let routeExpectation = expectation(description: "Routed")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            routeExpectation.fulfill()
        }
        wait(for: [routeExpectation], timeout: 1.0)

        // No streams should have received frames
        XCTAssertEqual(delegate1.sharedFrames.count, 0)
    }

    // MARK: - Control Channel Delegate Tests

    func testControlChannelDelegateRoutesFrameReady() async {
        let (stream1, delegate1) = makeStream(windowID: 100)

        // Create a mock shared frame buffer
        let bufferConfig = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let bufferPointer = createTestFrameBuffer(config: bufferConfig, windowID: 100, frameNumber: 42)
        let reader = SharedFrameBufferReader(
            pointer: bufferPointer,
            size: bufferConfig.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        router.setFrameBufferReader(reader)
        router.registerStream(stream1, forWindowID: 100)

        // Wait for setup
        try? await Task.sleep(for: .milliseconds(100))

        // Simulate receiving a FrameReady from control channel
        let channel = SpiceControlChannel()
        let notification = FrameReadyMessage(
            windowId: 100,
            slotIndex: 0,
            frameNumber: 42,
            isKeyFrame: true
        )

        router.controlChannel(channel, didReceiveFrameReady: notification)

        // Wait for routing
        let routeExpectation = expectation(description: "Routed")
        testQueue.asyncAfter(deadline: .now() + 0.2) {
            routeExpectation.fulfill()
        }
        await fulfillment(of: [routeExpectation], timeout: 1.0)

        XCTAssertEqual(delegate1.sharedFrames.count, 1)
        XCTAssertEqual(delegate1.sharedFrames.first?.frameNumber, 42)
    }

    // MARK: - Helper Methods

    /// Creates a test shared frame buffer with a single frame
    private func createTestFrameBuffer(
        config: SharedFrameBufferConfig,
        windowID: UInt64,
        frameNumber: UInt32
    ) -> UnsafeMutableRawPointer {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: config.totalSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: config.totalSize)

        // Write header
        var header = config.createHeader()
        header.writeIndex = 1  // One frame written
        header.readIndex = 0   // No frames read yet
        pointer.storeBytes(of: header, as: SharedFrameBufferHeader.self)

        // Write frame slot header
        let slotOffset = SharedFrameBufferHeader.size
        var slotHeader = FrameSlotHeader()
        slotHeader.windowId = windowID
        slotHeader.frameNumber = frameNumber
        slotHeader.width = 100
        slotHeader.height = 100
        slotHeader.stride = 400
        slotHeader.format = SpicePixelFormat.bgra32.rawValue.toUInt32()
        slotHeader.dataSize = 100 * 100 * 4
        slotHeader.flags = FrameSlotFlags.keyFrame.rawValue
        pointer.advanced(by: slotOffset).storeBytes(of: slotHeader, as: FrameSlotHeader.self)

        return pointer
    }
}

// MARK: - Helper Extensions

private extension UInt8 {
    func toUInt32() -> UInt32 {
        UInt32(self)
    }
}
