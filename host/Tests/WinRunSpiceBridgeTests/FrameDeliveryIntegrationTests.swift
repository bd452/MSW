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
    /// NOTE: This test uses the deprecated shared buffer path. Per-window buffers are now used.
    func testEndToEndFrameDeliveryPipeline() throws {
        throw XCTSkip("Test uses deprecated shared buffer path - per-window buffers are now used")

        // swiftlint:disable:next unused_declaration
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let (pointer, reader) = createReaderWithFrames(config: config, frames: [
            (windowId: 12345, frameNumber: 1)
        ])
        defer { pointer.deallocate() }

        let router = SpiceFrameRouter(logger: NullLogger())
        router.setFrameBufferReader(reader)

        let (stream, delegate) = createConnectedStream(windowID: 12345)
        router.registerStream(stream, forWindowID: 12345)
        waitForSetup()

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

    /// Tests that frames are routed to the correct window when multiple windows are active
    /// NOTE: This test uses the deprecated shared buffer path. Per-window buffers are now used.
    func testMultiWindowFrameRouting() throws {
        throw XCTSkip("Test uses deprecated shared buffer path - per-window buffers are now used")

        // swiftlint:disable:next unused_declaration
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let (pointer, reader) = createReaderWithFrames(config: config, frames: [
            (windowId: 100, frameNumber: 1),
            (windowId: 200, frameNumber: 1)
        ])
        defer { pointer.deallocate() }

        let router = SpiceFrameRouter(logger: NullLogger())
        router.setFrameBufferReader(reader)

        let (stream1, delegate1) = createConnectedStream(windowID: 100)
        let (stream2, delegate2) = createConnectedStream(windowID: 200)

        router.registerStream(stream1, forWindowID: 100)
        router.registerStream(stream2, forWindowID: 200)
        waitForSetup()

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
            windowId: 200, slotIndex: 1, frameNumber: 1, isKeyFrame: true
        ))
        waitForDelivery()

        // Now window 200's delegate should have the frame too
        XCTAssertEqual(delegate1.sharedFrames.count, 1)
        XCTAssertEqual(delegate2.sharedFrames.count, 1)
        XCTAssertEqual(delegate2.sharedFrames.first?.windowId, 200)
    }

    /// Tests that frame delivery metrics are updated correctly
    /// NOTE: This test uses the deprecated shared buffer path. Per-window buffers are now used.
    func testFrameDeliveryUpdatesMetrics() throws {
        throw XCTSkip("Test uses deprecated shared buffer path - per-window buffers are now used")

        // swiftlint:disable:next unused_declaration
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let (pointer, reader) = createReaderWithFrames(config: config, frames: [
            (windowId: 100, frameNumber: 1),
            (windowId: 100, frameNumber: 2),
            (windowId: 100, frameNumber: 3)
        ])
        defer { pointer.deallocate() }

        let router = SpiceFrameRouter(logger: NullLogger())
        router.setFrameBufferReader(reader)

        let (stream, delegate) = createConnectedStream(windowID: 100)
        router.registerStream(stream, forWindowID: 100)
        waitForSetup()

        // Send 3 frame notifications
        for i in 1...3 {
            router.routeFrameReady(FrameReadyMessage(
                windowId: 100,
                slotIndex: UInt32(i - 1),
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

    private func createReaderWithFrames(
        config: SharedFrameBufferConfig,
        frames: [(windowId: UInt64, frameNumber: UInt32)]
    ) -> (UnsafeMutableRawPointer, SharedFrameBufferReader) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: config.totalSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: config.totalSize)

        // Use bound pointer for proper alignment
        let headerPtr = pointer.bindMemory(to: SharedFrameBufferHeader.self, capacity: 1)
        var header = config.createHeader()
        header.writeIndex = UInt32(frames.count)
        header.readIndex = 0
        headerPtr.pointee = header

        for (index, frame) in frames.enumerated() {
            writeTestFrame(
                to: pointer,
                config: config,
                slotIndex: index,
                windowId: frame.windowId,
                frameNumber: frame.frameNumber
            )
        }

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: false, // We'll deallocate manually
            logger: NullLogger()
        )

        return (pointer, reader)
    }

    private func writeTestFrame(
        to pointer: UnsafeMutableRawPointer,
        config: SharedFrameBufferConfig,
        slotIndex: Int,
        windowId: UInt64,
        frameNumber: UInt32
    ) {
        let slotOffset = SharedFrameBufferHeader.size + slotIndex * config.slotSize

        var slotHeader = FrameSlotHeader()
        slotHeader.windowId = windowId
        slotHeader.frameNumber = frameNumber
        slotHeader.width = UInt32(config.maxWidth)
        slotHeader.height = UInt32(config.maxHeight)
        slotHeader.stride = UInt32(config.maxWidth * config.bytesPerPixel)
        slotHeader.format = UInt32(SpicePixelFormat.bgra32.rawValue)
        slotHeader.dataSize = UInt32(config.maxWidth * config.maxHeight * config.bytesPerPixel)
        slotHeader.flags = FrameSlotFlags.keyFrame.rawValue

        // Use bound pointer for proper alignment
        let slotPtr = pointer.advanced(by: slotOffset).bindMemory(to: FrameSlotHeader.self, capacity: 1)
        slotPtr.pointee = slotHeader
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
