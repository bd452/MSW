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

    /// NOTE: This test uses the deprecated shared buffer path. Per-window buffers are now used.
    func testFrameReadyRoutedToCorrectStream() throws {
        throw XCTSkip("Test uses deprecated shared buffer path - per-window buffers are now used")

        // swiftlint:disable:next unused_declaration
        let (stream1, delegate1) = makeStream(windowID: 100)
        // swiftlint:disable:next unused_declaration
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

    /// NOTE: This test uses the deprecated shared buffer path. Per-window buffers are now used.
    func testControlChannelDelegateRoutesFrameReady() async throws {
        throw XCTSkip("Test uses deprecated shared buffer path - per-window buffers are now used")

        // swiftlint:disable:next unused_declaration
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

    // MARK: - Per-Window Buffer Allocation Tests

    func testBufferAllocationStoresWindowBufferInfo() async {
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0x12345678,
            bufferSize: 8 * 1024 * 1024,
            slotSize: 2 * 1024 * 1024,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false
        )

        router.handleBufferAllocation(allocation)

        // Wait for async handling
        try? await Task.sleep(for: .milliseconds(100))

        let info = router.bufferInfo(forWindowID: 100)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.bufferPointer, 0x12345678)
        XCTAssertEqual(info?.bufferSize, 8 * 1024 * 1024)
        XCTAssertEqual(info?.slotSize, 2 * 1024 * 1024)
        XCTAssertEqual(info?.slotCount, 3)
        XCTAssertFalse(info?.isCompressed ?? true)
    }

    func testBufferReallocationUpdatesInfo() async {
        // Initial allocation
        let allocation1 = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0x1000,
            bufferSize: 1024,
            slotSize: 256,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false
        )
        router.handleBufferAllocation(allocation1)

        try? await Task.sleep(for: .milliseconds(50))

        // Reallocation
        let allocation2 = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0x2000,
            bufferSize: 2048,
            slotSize: 512,
            slotCount: 3,
            isCompressed: false,
            isReallocation: true
        )
        router.handleBufferAllocation(allocation2)

        try? await Task.sleep(for: .milliseconds(50))

        let info = router.bufferInfo(forWindowID: 100)
        XCTAssertEqual(info?.bufferPointer, 0x2000)
        XCTAssertEqual(info?.bufferSize, 2048)
        XCTAssertEqual(info?.slotSize, 512)
    }

    func testControlChannelDelegateHandlesBufferAllocation() async {
        let channel = SpiceControlChannel()
        let allocation = WindowBufferAllocatedMessage(
            windowId: 200,
            bufferPointer: 0xABCD,
            bufferSize: 4 * 1024 * 1024,
            slotSize: 1 * 1024 * 1024,
            slotCount: 3,
            isCompressed: true,
            isReallocation: false
        )

        router.controlChannel(channel, didReceiveBufferAllocation: allocation)

        try? await Task.sleep(for: .milliseconds(100))

        let info = router.bufferInfo(forWindowID: 200)
        XCTAssertNotNil(info)
        XCTAssertTrue(info?.isCompressed ?? false)
    }

    func testAllocatedBufferCountTracksAllocations() async {
        XCTAssertEqual(router.allocatedBufferCount, 0)

        let allocation1 = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0x1000,
            bufferSize: 1024,
            slotSize: 256,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false
        )
        router.handleBufferAllocation(allocation1)

        let allocation2 = WindowBufferAllocatedMessage(
            windowId: 200,
            bufferPointer: 0x2000,
            bufferSize: 1024,
            slotSize: 256,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false
        )
        router.handleBufferAllocation(allocation2)

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(router.allocatedBufferCount, 2)
    }

    func testUnregisterAllStreamsClearsBufferInfo() async {
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0x1000,
            bufferSize: 1024,
            slotSize: 256,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false
        )
        router.handleBufferAllocation(allocation)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(router.allocatedBufferCount, 1)

        router.unregisterAllStreams()

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(router.allocatedBufferCount, 0)
    }

    // MARK: - Helper Methods

    /// Creates a test shared frame buffer with a single frame
    private func createTestFrameBuffer(
        config: SharedFrameBufferConfig,
        windowID: UInt64,
        frameNumber: UInt32
    ) -> UnsafeMutableRawPointer {
        // Use proper alignment for both SharedFrameBufferHeader and FrameSlotHeader
        let headerStride = MemoryLayout<SharedFrameBufferHeader>.stride
        let slotHeaderStride = MemoryLayout<FrameSlotHeader>.stride
        let slotDataSize = config.maxWidth * config.maxHeight * config.bytesPerPixel
        let slotStride = slotHeaderStride + slotDataSize
        let totalSize = headerStride + config.slotCount * slotStride

        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: totalSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: totalSize)

        // Write header using bound pointer for proper alignment
        let headerPtr = pointer.bindMemory(to: SharedFrameBufferHeader.self, capacity: 1)
        var header = config.createHeader()
        header.writeIndex = 1  // One frame written
        header.readIndex = 0   // No frames read yet
        headerPtr.pointee = header

        // Write frame slot header with proper alignment
        let slotOffset = headerStride
        let slotPtr = pointer.advanced(by: slotOffset).bindMemory(to: FrameSlotHeader.self, capacity: 1)
        var slotHeader = FrameSlotHeader()
        slotHeader.windowId = windowID
        slotHeader.frameNumber = frameNumber
        slotHeader.width = 100
        slotHeader.height = 100
        slotHeader.stride = 400
        slotHeader.format = SpicePixelFormat.bgra32.rawValue.toUInt32()
        slotHeader.dataSize = 100 * 100 * 4
        slotHeader.flags = FrameSlotFlags.keyFrame.rawValue
        slotPtr.pointee = slotHeader

        return pointer
    }
}

// MARK: - Helper Extensions

private extension UInt8 {
    func toUInt32() -> UInt32 {
        UInt32(self)
    }
}
