import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - SpiceFrameRouter Shared Memory Tests

/// Tests for SpiceFrameRouter's per-window buffer mapping functionality.
/// These tests cover mapping guest buffer offsets to host memory.
final class SpiceFrameRouterSharedMemoryTests: XCTestCase {
    private var router: SpiceFrameRouter!
    private var transport: TestSpiceStreamTransport!
    private let testQueue = DispatchQueue(label: "test.frame-router-shm")

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

    // MARK: - Shared Memory Region Configuration Tests

    func testSetSharedMemoryRegionConfiguresRouter() async {
        XCTAssertFalse(router.hasSharedMemoryRegion)

        let regionSize = 1024 * 1024  // 1 MB
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { pointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: pointer, size: regionSize)

        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(router.hasSharedMemoryRegion)
    }

    func testClearSharedMemoryRegionResetsState() async {
        let regionSize = 1024 * 1024
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { pointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: pointer, size: regionSize)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(router.hasSharedMemoryRegion)

        router.clearSharedMemoryRegion()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(router.hasSharedMemoryRegion)
    }

    // MARK: - Reader Creation Tests

    func testSharedMemoryAllocationCreatesReader() async {
        // Set up shared memory region
        let regionSize = 10 * 1024 * 1024  // 10 MB
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: regionSize)
        defer { pointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: pointer, size: regionSize)
        try? await Task.sleep(for: .milliseconds(50))

        // Initialize the buffer header in the allocated region
        initializeBufferHeader(
            at: pointer,
            totalSize: 1024 * 1024,
            slotCount: 3,
            slotSize: 300_000
        )

        // Allocate buffer using shared memory
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0,  // Offset 0 in shared region
            bufferSize: 1024 * 1024,
            slotSize: 300_000,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        )
        router.handleBufferAllocation(allocation)

        try? await Task.sleep(for: .milliseconds(100))

        // Should have created a reader
        XCTAssertEqual(router.activeReaderCount, 1)
        XCTAssertNotNil(router.bufferReader(forWindowID: 100))
    }

    func testSharedMemoryAllocationDefersIfRegionNotSet() async {
        // Allocate buffer before setting shared memory region
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 1024,
            bufferSize: 1024 * 1024,
            slotSize: 300_000,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        )
        router.handleBufferAllocation(allocation)

        try? await Task.sleep(for: .milliseconds(50))

        // Should NOT have created a reader yet
        XCTAssertEqual(router.activeReaderCount, 0)
        XCTAssertNil(router.bufferReader(forWindowID: 100))

        // Buffer info should still be stored
        XCTAssertEqual(router.allocatedBufferCount, 1)
    }

    func testDeferredAllocationCreatesReaderWhenRegionSet() async {
        // Allocate buffer before setting shared memory region
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0,
            bufferSize: 1024 * 1024,
            slotSize: 300_000,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        )
        router.handleBufferAllocation(allocation)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(router.activeReaderCount, 0)

        // Now set the shared memory region
        let regionSize = 10 * 1024 * 1024
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: regionSize)
        defer { pointer.deallocate() }

        // Initialize buffer header
        initializeBufferHeader(
            at: pointer,
            totalSize: 1024 * 1024,
            slotCount: 3,
            slotSize: 300_000
        )

        router.setSharedMemoryRegion(basePointer: pointer, size: regionSize)

        try? await Task.sleep(for: .milliseconds(100))

        // Should have created a reader now
        XCTAssertEqual(router.activeReaderCount, 1)
        XCTAssertNotNil(router.bufferReader(forWindowID: 100))
    }

    // MARK: - Stream Integration Tests

    func testReaderAttachedToStreamOnAllocation() async {
        // Set up shared memory region
        let regionSize = 10 * 1024 * 1024
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: regionSize)
        defer { pointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: pointer, size: regionSize)
        try? await Task.sleep(for: .milliseconds(50))

        // Register stream first
        let (stream, _) = makeStream(windowID: 100)
        router.registerStream(stream, forWindowID: 100)

        try? await Task.sleep(for: .milliseconds(50))

        // Initialize buffer header
        initializeBufferHeader(
            at: pointer,
            totalSize: 1024 * 1024,
            slotCount: 3,
            slotSize: 300_000
        )

        // Allocate buffer
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0,
            bufferSize: 1024 * 1024,
            slotSize: 300_000,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        )
        router.handleBufferAllocation(allocation)

        try? await Task.sleep(for: .milliseconds(100))

        // Reader should be attached to stream
        XCTAssertEqual(router.activeReaderCount, 1)
    }

    func testReaderAttachedToStreamOnRegistration() async {
        // Set up shared memory region
        let regionSize = 10 * 1024 * 1024
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: regionSize)
        defer { pointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: pointer, size: regionSize)
        try? await Task.sleep(for: .milliseconds(50))

        // Initialize buffer header
        initializeBufferHeader(
            at: pointer,
            totalSize: 1024 * 1024,
            slotCount: 3,
            slotSize: 300_000
        )

        // Allocate buffer first (before stream registration)
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0,
            bufferSize: 1024 * 1024,
            slotSize: 300_000,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        )
        router.handleBufferAllocation(allocation)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(router.activeReaderCount, 1)

        // Now register stream - should attach existing reader
        let (stream, _) = makeStream(windowID: 100)
        router.registerStream(stream, forWindowID: 100)

        try? await Task.sleep(for: .milliseconds(100))

        // Reader should still exist
        XCTAssertNotNil(router.bufferReader(forWindowID: 100))
    }

    // MARK: - Validation Tests

    func testInvalidBufferOffsetIsRejected() async {
        // Set up small shared memory region
        let regionSize = 1024 * 1024  // 1 MB
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { pointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: pointer, size: regionSize)
        try? await Task.sleep(for: .milliseconds(50))

        // Try to allocate buffer that exceeds region size
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 512 * 1024,  // Offset + size would exceed region
            bufferSize: 1024 * 1024,    // This would go past the end
            slotSize: 300_000,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: true
        )
        router.handleBufferAllocation(allocation)

        try? await Task.sleep(for: .milliseconds(100))

        // Should NOT have created a reader due to bounds check
        XCTAssertEqual(router.activeReaderCount, 0)
        XCTAssertNil(router.bufferReader(forWindowID: 100))
        // Buffer info should still be stored
        XCTAssertEqual(router.allocatedBufferCount, 1)
    }

    func testNonSharedMemoryAllocationSkipsReaderCreation() async {
        // Set up shared memory region
        let regionSize = 10 * 1024 * 1024
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: regionSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { pointer.deallocate() }

        router.setSharedMemoryRegion(basePointer: pointer, size: regionSize)
        try? await Task.sleep(for: .milliseconds(50))

        // Allocate buffer NOT using shared memory
        let allocation = WindowBufferAllocatedMessage(
            windowId: 100,
            bufferPointer: 0x12345678,  // Guest-local pointer
            bufferSize: 1024 * 1024,
            slotSize: 300_000,
            slotCount: 3,
            isCompressed: false,
            isReallocation: false,
            usesSharedMemory: false  // Not using shared memory
        )
        router.handleBufferAllocation(allocation)

        try? await Task.sleep(for: .milliseconds(100))

        // Should NOT create a reader for non-shared-memory buffers
        XCTAssertEqual(router.activeReaderCount, 0)
        XCTAssertNil(router.bufferReader(forWindowID: 100))
        // But buffer info should still be stored
        XCTAssertEqual(router.allocatedBufferCount, 1)
    }

    // MARK: - Helper Methods

    /// Initializes a valid SharedFrameBufferHeader at the given pointer
    private func initializeBufferHeader(
        at pointer: UnsafeMutableRawPointer,
        totalSize: Int,
        slotCount: Int,
        slotSize: Int
    ) {
        let headerPtr = pointer.bindMemory(to: SharedFrameBufferHeader.self, capacity: 1)
        var header = SharedFrameBufferHeader()
        header.magic = SharedFrameBufferMagic
        header.version = SharedFrameBufferVersion
        header.totalSize = UInt32(totalSize)
        header.slotCount = UInt32(slotCount)
        header.slotSize = UInt32(slotSize)
        header.maxWidth = 1920
        header.maxHeight = 1080
        header.writeIndex = 0
        header.readIndex = 0
        header.flags = 0
        headerPtr.pointee = header
    }
}
