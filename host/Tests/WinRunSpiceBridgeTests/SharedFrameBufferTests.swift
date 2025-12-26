import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - SharedFrameBufferHeader Tests

final class SharedFrameBufferHeaderTests: XCTestCase {
    func testHeaderSize() {
        XCTAssertEqual(SharedFrameBufferHeader.size, 64)
    }

    func testDefaultHeaderHasCorrectMagic() {
        let header = SharedFrameBufferHeader()
        XCTAssertEqual(header.magic, SharedFrameBufferMagic)
    }

    func testDefaultHeaderHasCorrectVersion() {
        let header = SharedFrameBufferHeader()
        XCTAssertEqual(header.version, SharedFrameBufferVersion)
    }

    func testIsValidWithCorrectMagicAndVersion() {
        let header = SharedFrameBufferHeader()
        XCTAssertTrue(header.isValid)
    }

    func testIsValidFailsWithWrongMagic() {
        var header = SharedFrameBufferHeader()
        header.magic = 0x12345678
        XCTAssertFalse(header.isValid)
    }

    func testIsValidFailsWithWrongVersion() {
        var header = SharedFrameBufferHeader()
        header.version = 999
        XCTAssertFalse(header.isValid)
    }

    func testAvailableFramesWhenWriteAheadOfRead() {
        var header = SharedFrameBufferHeader()
        header.slotCount = 5
        header.writeIndex = 3
        header.readIndex = 1
        XCTAssertEqual(header.availableFrames, 2)
    }

    func testAvailableFramesWhenWriteWrapsAround() {
        var header = SharedFrameBufferHeader()
        header.slotCount = 5
        header.writeIndex = 1
        header.readIndex = 4
        XCTAssertEqual(header.availableFrames, 2) // 5 - 4 + 1 = 2
    }

    func testAvailableFramesWhenEmpty() {
        var header = SharedFrameBufferHeader()
        header.slotCount = 5
        header.writeIndex = 2
        header.readIndex = 2
        XCTAssertEqual(header.availableFrames, 0)
    }

    func testHasFramesWhenWriteAheadOfRead() {
        var header = SharedFrameBufferHeader()
        header.writeIndex = 3
        header.readIndex = 1
        XCTAssertTrue(header.hasFrames)
    }

    func testHasFramesWhenEmpty() {
        var header = SharedFrameBufferHeader()
        header.writeIndex = 2
        header.readIndex = 2
        XCTAssertFalse(header.hasFrames)
    }
}

// MARK: - FrameSlotHeader Tests

final class FrameSlotHeaderTests: XCTestCase {
    func testSlotHeaderSize() {
        XCTAssertEqual(FrameSlotHeader.size, 36)
    }

    func testDefaultSlotHeaderIsZeroed() {
        let slotHeader = FrameSlotHeader()
        XCTAssertEqual(slotHeader.windowId, 0)
        XCTAssertEqual(slotHeader.frameNumber, 0)
        XCTAssertEqual(slotHeader.width, 0)
        XCTAssertEqual(slotHeader.height, 0)
        XCTAssertEqual(slotHeader.stride, 0)
        XCTAssertEqual(slotHeader.format, 0)
        XCTAssertEqual(slotHeader.dataSize, 0)
        XCTAssertEqual(slotHeader.flags, 0)
    }
}

// MARK: - FrameSlotFlags Tests

final class FrameSlotFlagsTests: XCTestCase {
    func testCompressedFlag() {
        let flags = FrameSlotFlags.compressed
        XCTAssertEqual(flags.rawValue, 1)
        XCTAssertTrue(flags.contains(.compressed))
        XCTAssertFalse(flags.contains(.keyFrame))
    }

    func testKeyFrameFlag() {
        let flags = FrameSlotFlags.keyFrame
        XCTAssertEqual(flags.rawValue, 2)
        XCTAssertTrue(flags.contains(.keyFrame))
        XCTAssertFalse(flags.contains(.compressed))
    }

    func testCombinedFlags() {
        let flags: FrameSlotFlags = [.compressed, .keyFrame]
        XCTAssertEqual(flags.rawValue, 3)
        XCTAssertTrue(flags.contains(.compressed))
        XCTAssertTrue(flags.contains(.keyFrame))
    }
}

// MARK: - SharedFrameBufferConfig Tests

final class SharedFrameBufferConfigTests: XCTestCase {
    func testDefaultConfig() {
        let config = SharedFrameBufferConfig()
        XCTAssertEqual(config.slotCount, 3)
        XCTAssertEqual(config.maxWidth, 3840)
        XCTAssertEqual(config.maxHeight, 2160)
        XCTAssertEqual(config.bytesPerPixel, 4)
    }

    func testSlotSizeCalculation() {
        let config = SharedFrameBufferConfig(
            slotCount: 2,
            maxWidth: 100,
            maxHeight: 100,
            bytesPerPixel: 4
        )
        // slotSize = FrameSlotHeader.size + maxWidth * maxHeight * bytesPerPixel
        // slotSize = 36 + 100 * 100 * 4 = 36 + 40000 = 40036
        XCTAssertEqual(config.slotSize, 40036)
    }

    func testTotalSizeCalculation() {
        let config = SharedFrameBufferConfig(
            slotCount: 2,
            maxWidth: 100,
            maxHeight: 100,
            bytesPerPixel: 4
        )
        // totalSize = header + slotCount * slotSize
        // totalSize = 64 + 2 * 40036 = 64 + 80072 = 80136
        XCTAssertEqual(config.totalSize, 80136)
    }

    func testCreateHeaderFromConfig() {
        let config = SharedFrameBufferConfig(
            slotCount: 3,
            maxWidth: 800,
            maxHeight: 600,
            bytesPerPixel: 4
        )

        let header = config.createHeader()

        XCTAssertEqual(header.magic, SharedFrameBufferMagic)
        XCTAssertEqual(header.version, SharedFrameBufferVersion)
        XCTAssertEqual(header.slotCount, 3)
        XCTAssertEqual(header.maxWidth, 800)
        XCTAssertEqual(header.maxHeight, 600)
        XCTAssertEqual(header.slotSize, UInt32(config.slotSize))
        XCTAssertEqual(header.totalSize, UInt32(config.totalSize))
    }
}

// MARK: - SharedFrameBufferReader Tests

final class SharedFrameBufferReaderTests: XCTestCase {
    func testValidateSucceedsWithValidBuffer() throws {
        let config = SharedFrameBufferConfig(slotCount: 2, maxWidth: 100, maxHeight: 100)
        let (pointer, _) = createValidBuffer(config: config)

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        XCTAssertNoThrow(try reader.validate())
    }

    func testValidateFailsWithBufferTooSmall() {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 10, alignment: 8)
        defer { pointer.deallocate() }

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: 10,
            ownsMemory: false,
            logger: NullLogger()
        )

        XCTAssertThrowsError(try reader.validate()) { error in
            guard case SharedFrameBufferError.bufferTooSmall = error else {
                XCTFail("Expected bufferTooSmall error")
                return
            }
        }
    }

    func testValidateFailsWithInvalidMagic() {
        let config = SharedFrameBufferConfig(slotCount: 2, maxWidth: 100, maxHeight: 100)
        let (pointer, _) = createValidBuffer(config: config)

        // Corrupt the magic number
        pointer.storeBytes(of: UInt32(0xDEADBEEF), as: UInt32.self)

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        XCTAssertThrowsError(try reader.validate()) { error in
            guard case SharedFrameBufferError.invalidMagic = error else {
                XCTFail("Expected invalidMagic error")
                return
            }
        }
    }

    func testReadHeaderReturnsCorrectData() {
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 800, maxHeight: 600)
        let (pointer, _) = createValidBuffer(config: config)

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        let header = reader.readHeader()
        XCTAssertEqual(header.magic, SharedFrameBufferMagic)
        XCTAssertEqual(header.slotCount, 3)
        XCTAssertEqual(header.maxWidth, 800)
        XCTAssertEqual(header.maxHeight, 600)
    }

    func testHasFramesWhenEmpty() {
        let config = SharedFrameBufferConfig(slotCount: 2, maxWidth: 100, maxHeight: 100)
        let (pointer, _) = createValidBuffer(config: config)

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        XCTAssertFalse(reader.hasFrames)
        XCTAssertEqual(reader.availableFrameCount, 0)
    }

    func testReadNextFrameReturnsNilWhenEmpty() throws {
        let config = SharedFrameBufferConfig(slotCount: 2, maxWidth: 100, maxHeight: 100)
        let (pointer, _) = createValidBuffer(config: config)

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        let frame = try reader.readNextFrame()
        XCTAssertNil(frame)
    }

    func testReadNextFrameReturnsFrameWhenAvailable() throws {
        let config = SharedFrameBufferConfig(slotCount: 2, maxWidth: 100, maxHeight: 100)
        let (pointer, _) = createValidBuffer(config: config, frameCount: 1)

        // Write a frame to slot 0
        writeTestFrame(to: pointer, config: config, slotIndex: 0, windowId: 12345, frameNumber: 1)

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        XCTAssertTrue(reader.hasFrames)
        XCTAssertEqual(reader.availableFrameCount, 1)

        let frame = try reader.readNextFrame()
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.windowId, 12345)
        XCTAssertEqual(frame?.frameNumber, 1)
        XCTAssertEqual(frame?.width, 100)
        XCTAssertEqual(frame?.height, 100)
    }

    func testReadNextFrameAdvancesReadIndex() throws {
        let config = SharedFrameBufferConfig(slotCount: 3, maxWidth: 100, maxHeight: 100)
        let (pointer, _) = createValidBuffer(config: config, frameCount: 2)

        // Write two frames
        writeTestFrame(to: pointer, config: config, slotIndex: 0, windowId: 100, frameNumber: 1)
        writeTestFrame(to: pointer, config: config, slotIndex: 1, windowId: 100, frameNumber: 2)

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        XCTAssertEqual(reader.availableFrameCount, 2)

        let frame1 = try reader.readNextFrame()
        XCTAssertEqual(frame1?.frameNumber, 1)
        XCTAssertEqual(reader.availableFrameCount, 1)

        let frame2 = try reader.readNextFrame()
        XCTAssertEqual(frame2?.frameNumber, 2)
        XCTAssertEqual(reader.availableFrameCount, 0)

        let frame3 = try reader.readNextFrame()
        XCTAssertNil(frame3)
    }

    func testSetHostActive() {
        let config = SharedFrameBufferConfig(slotCount: 2, maxWidth: 100, maxHeight: 100)
        let (pointer, _) = createValidBuffer(config: config)

        let reader = SharedFrameBufferReader(
            pointer: pointer,
            size: config.totalSize,
            ownsMemory: true,
            logger: NullLogger()
        )

        reader.setHostActive(true)
        var header = reader.readHeader()
        let flags = SharedFrameBufferFlags(rawValue: header.flags)
        XCTAssertTrue(flags.contains(.hostActive))

        reader.setHostActive(false)
        header = reader.readHeader()
        let flags2 = SharedFrameBufferFlags(rawValue: header.flags)
        XCTAssertFalse(flags2.contains(.hostActive))
    }

    // MARK: - Helper Methods

    private func createValidBuffer(
        config: SharedFrameBufferConfig,
        frameCount: Int = 0
    ) -> (UnsafeMutableRawPointer, SharedFrameBufferHeader) {
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: config.totalSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: config.totalSize)

        var header = config.createHeader()
        header.writeIndex = UInt32(frameCount)
        header.readIndex = 0
        pointer.storeBytes(of: header, as: SharedFrameBufferHeader.self)

        return (pointer, header)
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

        pointer.advanced(by: slotOffset).storeBytes(of: slotHeader, as: FrameSlotHeader.self)

        // Fill frame data with a test pattern
        let dataOffset = slotOffset + FrameSlotHeader.size
        let dataPtr = pointer.advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(slotHeader.dataSize) {
            dataPtr[i] = UInt8(i % 256)
        }
    }
}

// MARK: - FrameReadyMessage Tests

final class FrameReadyMessageTests: XCTestCase {
    func testFrameReadyMessageCreation() {
        let message = FrameReadyMessage(
            windowId: 12345,
            slotIndex: 2,
            frameNumber: 42,
            isKeyFrame: true
        )

        XCTAssertEqual(message.windowId, 12345)
        XCTAssertEqual(message.slotIndex, 2)
        XCTAssertEqual(message.frameNumber, 42)
        XCTAssertTrue(message.isKeyFrame)
        XCTAssertGreaterThan(message.timestamp, 0)
    }

    func testFrameReadyMessageEncoding() throws {
        let message = FrameReadyMessage(
            timestamp: 1700000000000,
            windowId: 12345,
            slotIndex: 2,
            frameNumber: 42,
            isKeyFrame: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"windowId\":12345"))
        XCTAssertTrue(json.contains("\"slotIndex\":2"))
        XCTAssertTrue(json.contains("\"frameNumber\":42"))
        XCTAssertTrue(json.contains("\"isKeyFrame\":false"))
    }

    func testFrameReadyMessageDecoding() throws {
        let json = """
        {
            "timestamp": 1700000000000,
            "windowId": 12345,
            "slotIndex": 2,
            "frameNumber": 42,
            "isKeyFrame": true
        }
        """

        let decoder = JSONDecoder()
        let message = try decoder.decode(FrameReadyMessage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(message.timestamp, 1700000000000)
        XCTAssertEqual(message.windowId, 12345)
        XCTAssertEqual(message.slotIndex, 2)
        XCTAssertEqual(message.frameNumber, 42)
        XCTAssertTrue(message.isKeyFrame)
    }
}

// MARK: - SharedFrame Tests

final class SharedFrameTests: XCTestCase {
    func testSharedFrameCreation() {
        let testData = Data([0x01, 0x02, 0x03, 0x04])
        let frame = SharedFrame(
            windowId: 100,
            frameNumber: 5,
            width: 800,
            height: 600,
            stride: 3200,
            format: .bgra32,
            data: testData,
            isCompressed: false
        )

        XCTAssertEqual(frame.windowId, 100)
        XCTAssertEqual(frame.frameNumber, 5)
        XCTAssertEqual(frame.width, 800)
        XCTAssertEqual(frame.height, 600)
        XCTAssertEqual(frame.stride, 3200)
        XCTAssertEqual(frame.format, .bgra32)
        XCTAssertEqual(frame.data, testData)
        XCTAssertFalse(frame.isCompressed)
    }

    func testSharedFrameWithCompression() {
        let testData = Data([0xAB, 0xCD, 0xEF])
        let frame = SharedFrame(
            windowId: 200,
            frameNumber: 10,
            width: 1920,
            height: 1080,
            stride: 7680,
            format: .rgba32,
            data: testData,
            isCompressed: true
        )

        XCTAssertEqual(frame.format, .rgba32)
        XCTAssertTrue(frame.isCompressed)
    }
}
