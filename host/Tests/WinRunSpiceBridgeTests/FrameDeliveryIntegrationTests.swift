import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - Integration Tests for End-to-End Frame Delivery

final class FrameDeliveryIntegrationTests: XCTestCase {
    private var transport: TestSpiceStreamTransport!
    private let testQueue = DispatchQueue(label: "test.frame-delivery")

    override func setUp() {
        super.setUp()
        transport = TestSpiceStreamTransport()
    }

    override func tearDown() {
        transport = nil
        super.tearDown()
    }

    /// Tests the full pipeline: FrameReady notification → Router → Stream → Delegate
    /// Uses per-window buffer allocation with shared memory region.
    func testEndToEndFrameDeliveryPipeline() async {
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let regionPointer = UnsafeMutableRawPointer.allocate(
            byteCount: config.totalSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        regionPointer.initializeMemory(as: UInt8.self, repeating: 0, count: config.totalSize)
        defer { regionPointer.deallocate() }

        let router = SpiceFrameRouter(logger: NullLogger())

        // Set up shared memory region
        router.setSharedMemoryRegion(basePointer: regionPointer, size: config.totalSize)
        try? await Task.sleep(for: .milliseconds(50))

        let (stream, delegate) = createConnectedStream(windowID: 12345)
        router.registerStream(stream, forWindowID: 12345)
        waitForSetup()

        // Initialize buffer with frame data
        initializePerWindowBuffer(
            at: regionPointer,
            offset: 0,
            config: config,
            windowID: 12345,
            frameNumber: 1
        )

        // Allocate per-window buffer
        let allocation = WindowBufferAllocatedMessage(
            windowId: 12345,
            bufferPointer: 0,
            bufferSize: Int32(config.totalSize),
            slotSize: Int32(config.slotSize),
            slotCount: Int32(config.slotCount),
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        )
        router.handleBufferAllocation(allocation)
        try? await Task.sleep(for: .milliseconds(100))

        // Simulate receiving a FrameReady notification
        router.routeFrameReady(FrameReadyMessage(
            windowId: 12345,
            slotIndex: 0,
            frameNumber: 1,
            isKeyFrame: true
        ))

        waitForDelivery()

        // Verify frame was delivered
        XCTAssertEqual(delegate.sharedFrames.count, 1)
        XCTAssertEqual(delegate.sharedFrames.first?.windowId, 12345)
        XCTAssertEqual(delegate.sharedFrames.first?.frameNumber, 1)
        XCTAssertEqual(delegate.sharedFrames.first?.width, 100)
        XCTAssertEqual(delegate.sharedFrames.first?.height, 100)
    }

    /// Tests that frames are routed to the correct window when multiple windows are active.
    /// Uses per-window buffer allocation with shared memory region.
    func testMultiWindowFrameRouting() async {
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let regionSize = config.totalSize * 2  // Space for 2 windows
        let regionPointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        regionPointer.initializeMemory(as: UInt8.self, repeating: 0, count: regionSize)
        defer { regionPointer.deallocate() }

        let router = SpiceFrameRouter(logger: NullLogger())

        // Set up shared memory region
        router.setSharedMemoryRegion(basePointer: regionPointer, size: regionSize)
        try? await Task.sleep(for: .milliseconds(50))

        let (stream1, delegate1) = createConnectedStream(windowID: 100)
        let (stream2, delegate2) = createConnectedStream(windowID: 200)

        router.registerStream(stream1, forWindowID: 100)
        router.registerStream(stream2, forWindowID: 200)
        waitForSetup()

        // Initialize and allocate buffer for window 100
        let window1Offset = 0
        initializePerWindowBuffer(at: regionPointer, offset: window1Offset, config: config, windowID: 100, frameNumber: 1)
        router.handleBufferAllocation(WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: UInt64(window1Offset),
            bufferSize: Int32(config.totalSize),
            slotSize: Int32(config.slotSize),
            slotCount: Int32(config.slotCount),
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        ))

        // Initialize and allocate buffer for window 200
        let window2Offset = config.totalSize
        initializePerWindowBuffer(at: regionPointer, offset: window2Offset, config: config, windowID: 200, frameNumber: 1)
        router.handleBufferAllocation(WindowBufferAllocatedMessage(
            windowId: 200,
            bufferPointer: UInt64(window2Offset),
            bufferSize: Int32(config.totalSize),
            slotSize: Int32(config.slotSize),
            slotCount: Int32(config.slotCount),
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        ))

        try? await Task.sleep(for: .milliseconds(100))

        // Send notification for window 100
        router.routeFrameReady(FrameReadyMessage(
            windowId: 100, slotIndex: 0, frameNumber: 1, isKeyFrame: true
        ))
        waitForDelivery()

        // Only window 100's delegate should have received the frame
        XCTAssertEqual(delegate1.sharedFrames.count, 1)
        XCTAssertEqual(delegate1.sharedFrames.first?.windowId, 100)
        XCTAssertEqual(delegate2.sharedFrames.count, 0)

        // Now send notification for window 200
        router.routeFrameReady(FrameReadyMessage(
            windowId: 200, slotIndex: 0, frameNumber: 1, isKeyFrame: true
        ))
        waitForDelivery()

        // Now window 200's delegate should have the frame too
        XCTAssertEqual(delegate1.sharedFrames.count, 1)
        XCTAssertEqual(delegate2.sharedFrames.count, 1)
        XCTAssertEqual(delegate2.sharedFrames.first?.windowId, 200)
    }

    /// Tests that frame delivery metrics are updated correctly.
    /// Uses per-window buffer allocation with shared memory region.
    func testFrameDeliveryUpdatesMetrics() async {
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let regionPointer = UnsafeMutableRawPointer.allocate(
            byteCount: config.totalSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        regionPointer.initializeMemory(as: UInt8.self, repeating: 0, count: config.totalSize)
        defer { regionPointer.deallocate() }

        let router = SpiceFrameRouter(logger: NullLogger())

        // Set up shared memory region
        router.setSharedMemoryRegion(basePointer: regionPointer, size: config.totalSize)
        try? await Task.sleep(for: .milliseconds(50))

        let (stream, delegate) = createConnectedStream(windowID: 100)
        router.registerStream(stream, forWindowID: 100)
        waitForSetup()

        // Initialize buffer with frame data (we'll update writeIndex for each frame)
        initializePerWindowBuffer(at: regionPointer, offset: 0, config: config, windowID: 100, frameNumber: 1)

        // Allocate per-window buffer
        router.handleBufferAllocation(WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0,
            bufferSize: Int32(config.totalSize),
            slotSize: Int32(config.slotSize),
            slotCount: Int32(config.slotCount),
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        ))
        try? await Task.sleep(for: .milliseconds(100))

        // Send 3 frame notifications (updating buffer state for each)
        for i in 1...3 {
            // Update the frame in the buffer
            updateFrameInBuffer(at: regionPointer, config: config, frameNumber: UInt32(i))

            router.routeFrameReady(FrameReadyMessage(
                windowId: 100,
                slotIndex: 0,  // Always slot 0 for simplicity
                frameNumber: UInt32(i),
                isKeyFrame: i == 1
            ))
        }
        waitForDelivery(delay: 0.3)

        let metrics = stream.metricsSnapshot()
        XCTAssertEqual(metrics.framesReceived, 3)
        XCTAssertEqual(delegate.sharedFrames.count, 3)
    }

    // MARK: - Helper Methods

    /// Initializes a per-window buffer at a given offset in the shared memory region
    private func initializePerWindowBuffer(
        at regionPointer: UnsafeMutableRawPointer,
        offset: Int,
        config: SharedFrameBufferConfig,
        windowID: UInt64,
        frameNumber: UInt32
    ) {
        let bufferPtr = regionPointer.advanced(by: offset)

        // Initialize header
        let headerPtr = bufferPtr.bindMemory(to: SharedFrameBufferHeader.self, capacity: 1)
        var header = config.createHeader()
        header.writeIndex = 1  // One frame written
        header.readIndex = 0   // No frames read yet
        headerPtr.pointee = header

        // Initialize frame slot
        let slotOffset = SharedFrameBufferHeader.size
        let slotPtr = bufferPtr.advanced(by: slotOffset).bindMemory(to: FrameSlotHeader.self, capacity: 1)
        var slotHeader = FrameSlotHeader()
        slotHeader.windowId = windowID
        slotHeader.frameNumber = frameNumber
        slotHeader.width = UInt32(config.maxWidth)
        slotHeader.height = UInt32(config.maxHeight)
        slotHeader.stride = UInt32(config.maxWidth * config.bytesPerPixel)
        slotHeader.format = UInt32(SpicePixelFormat.bgra32.rawValue)
        slotHeader.dataSize = UInt32(config.maxWidth * config.maxHeight * config.bytesPerPixel)
        slotHeader.flags = FrameSlotFlags.keyFrame.rawValue
        slotPtr.pointee = slotHeader
    }

    /// Updates the frame number in the buffer and resets read/write indices
    private func updateFrameInBuffer(
        at regionPointer: UnsafeMutableRawPointer,
        config: SharedFrameBufferConfig,
        frameNumber: UInt32
    ) {
        // Reset header indices
        let headerPtr = regionPointer.bindMemory(to: SharedFrameBufferHeader.self, capacity: 1)
        headerPtr.pointee.writeIndex = 1
        headerPtr.pointee.readIndex = 0

        // Update frame slot
        let slotOffset = SharedFrameBufferHeader.size
        let slotPtr = regionPointer.advanced(by: slotOffset).bindMemory(to: FrameSlotHeader.self, capacity: 1)
        slotPtr.pointee.frameNumber = frameNumber
    }

    private func createConnectedStream(
        windowID: UInt64
    ) -> (SpiceWindowStream, TestSpiceWindowStreamDelegate) {
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

        let connectExpectation = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) {
            connectExpectation.fulfill()
        }
        wait(for: [connectExpectation], timeout: 1.0)

        return (stream, delegate)
    }

    private func waitForSetup() {
        let exp = expectation(description: "Setup")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    private func waitForDelivery(delay: TimeInterval = 0.2) {
        let exp = expectation(description: "Delivery")
        testQueue.asyncAfter(deadline: .now() + delay) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
