import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

final class SpiceFrameRouterIsolationTests: XCTestCase {
    private var router: SpiceFrameRouter!
    private var transport: TestSpiceStreamTransport!
    private let testQueue = DispatchQueue(label: "test.frame-router-isolation")

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

    func testUnregisteringOneWindowDoesNotImpactOtherWindowRouting() async {
        let (stream1, delegate1) = makeStream(windowID: 100)
        let (stream2, delegate2) = makeStream(windowID: 200)
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let perWindowBufferSize = config.slotSize * config.slotCount
        let regionSize = perWindowBufferSize * 2

        let regionPointer = allocateRegion(size: regionSize)
        defer { regionPointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: regionPointer, size: regionSize)
        await waitForRouterWork()
        router.registerStream(stream1, forWindowID: 100)
        router.registerStream(stream2, forWindowID: 200)
        await waitForRouterWork()

        initializeBufferAtOffset(regionPointer, offset: 0, config: config, windowID: 100, frameNumber: 1)
        initializeBufferAtOffset(regionPointer, offset: perWindowBufferSize, config: config, windowID: 200, frameNumber: 2)
        allocateWindowBuffer(windowID: 100, offset: 0, size: perWindowBufferSize, config: config)
        allocateWindowBuffer(windowID: 200, offset: perWindowBufferSize, size: perWindowBufferSize, config: config)
        await waitForRouterWork()

        router.unregisterStream(forWindowID: 100)
        await waitForRouterWork()

        XCTAssertEqual(router.registeredStreamCount, 1)
        XCTAssertNil(router.bufferInfo(forWindowID: 100))
        XCTAssertNotNil(router.bufferInfo(forWindowID: 200))

        router.routeFrameReady(FrameReadyMessage(windowId: 100, slotIndex: 0, frameNumber: 1, isKeyFrame: true))
        router.routeFrameReady(FrameReadyMessage(windowId: 200, slotIndex: 0, frameNumber: 2, isKeyFrame: true))
        await waitForDelivery()

        XCTAssertEqual(delegate1.sharedFrames.count, 0)
        XCTAssertEqual(delegate2.sharedFrames.count, 1)
        XCTAssertEqual(delegate2.sharedFrames.first?.windowId, 200)
    }

    func testReallocationForOneWindowKeepsOtherWindowReaderStable() async {
        let (stream1, _) = makeStream(windowID: 100)
        let (stream2, delegate2) = makeStream(windowID: 200)
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let perWindowBufferSize = config.slotSize * config.slotCount
        let regionSize = perWindowBufferSize * 3

        let regionPointer = allocateRegion(size: regionSize)
        defer { regionPointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: regionPointer, size: regionSize)
        await waitForRouterWork()
        router.registerStream(stream1, forWindowID: 100)
        router.registerStream(stream2, forWindowID: 200)
        await waitForRouterWork()

        initializeBufferAtOffset(regionPointer, offset: 0, config: config, windowID: 100, frameNumber: 1)
        initializeBufferAtOffset(regionPointer, offset: perWindowBufferSize, config: config, windowID: 200, frameNumber: 2)
        allocateWindowBuffer(windowID: 100, offset: 0, size: perWindowBufferSize, config: config)
        allocateWindowBuffer(windowID: 200, offset: perWindowBufferSize, size: perWindowBufferSize, config: config)
        await waitForRouterWork()

        guard
            let reader100Before = router.bufferReader(forWindowID: 100),
            let reader200Before = router.bufferReader(forWindowID: 200)
        else {
            XCTFail("Expected readers for both windows before reallocation")
            return
        }

        let reallocatedOffset = perWindowBufferSize * 2
        initializeBufferAtOffset(regionPointer, offset: reallocatedOffset, config: config, windowID: 100, frameNumber: 3)
        allocateWindowBuffer(windowID: 100, offset: reallocatedOffset, size: perWindowBufferSize, config: config, isReallocation: true)
        await waitForRouterWork()

        guard
            let reader100After = router.bufferReader(forWindowID: 100),
            let reader200After = router.bufferReader(forWindowID: 200)
        else {
            XCTFail("Expected readers for both windows after reallocation")
            return
        }

        XCTAssertNotEqual(ObjectIdentifier(reader100Before), ObjectIdentifier(reader100After))
        XCTAssertEqual(ObjectIdentifier(reader200Before), ObjectIdentifier(reader200After))

        router.routeFrameReady(FrameReadyMessage(windowId: 200, slotIndex: 0, frameNumber: 2, isKeyFrame: true))
        await waitForDelivery()
        XCTAssertEqual(delegate2.sharedFrames.count, 1)
        XCTAssertEqual(delegate2.sharedFrames.first?.windowId, 200)
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

        let connected = expectation(description: "Connected")
        testQueue.asyncAfter(deadline: .now() + 0.1) { connected.fulfill() }
        wait(for: [connected], timeout: 1.0)
        return (stream, delegate)
    }

    private func allocateRegion(size: Int) -> UnsafeMutableRawPointer {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        return pointer
    }

    private func allocateWindowBuffer(
        windowID: UInt64,
        offset: Int,
        size: Int,
        config: SharedFrameBufferConfig,
        isReallocation: Bool = false
    ) {
        router.handleBufferAllocation(WindowBufferAllocatedMessage(
            windowId: windowID,
            bufferPointer: UInt64(offset),
            bufferSize: Int32(size),
            slotSize: Int32(config.slotSize),
            slotCount: Int32(config.slotCount),
            isCompressed: false,
            isReallocation: isReallocation,
            usesSharedMemory: true
        ))
    }

    private func initializeBufferAtOffset(
        _ regionPointer: UnsafeMutableRawPointer,
        offset: Int,
        config: SharedFrameBufferConfig,
        windowID: UInt64,
        frameNumber: UInt32
    ) {
        let bufferPtr = regionPointer.advanced(by: offset)
        let slotPtr = bufferPtr.bindMemory(to: FrameSlotHeader.self, capacity: 1)
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

    private func waitForRouterWork() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func waitForDelivery() async {
        let routed = expectation(description: "Delivery")
        testQueue.asyncAfter(deadline: .now() + 0.2) { routed.fulfill() }
        await fulfillment(of: [routed], timeout: 1.0)
    }
}
