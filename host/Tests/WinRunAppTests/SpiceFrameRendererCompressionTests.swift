import XCTest
import Compression
@testable import WinRunApp

@available(macOS 13, *)
final class SpiceFrameRendererCompressionTests: XCTestCase {
    func testDecompressLZ4FrameDataRoundTrip() throws {
        let original = Data((0..<4096).map { UInt8($0 % 251) })
        let compressed = try compressLZ4(original)

        let decompressed = SpiceFrameRenderer.decompressLZ4FrameData(
            compressed,
            expectedSize: original.count
        )

        XCTAssertEqual(decompressed, original)
    }

    func testDecompressLZ4FrameDataReturnsNilForInvalidPayload() {
        let invalidCompressedPayload = Data([0x00, 0x01, 0x02, 0x03, 0x04])

        let decompressed = SpiceFrameRenderer.decompressLZ4FrameData(
            invalidCompressedPayload,
            expectedSize: 1024
        )

        XCTAssertNil(decompressed)
    }

    func testDecompressLZ4FrameDataReturnsNilWhenSizeDoesNotMatch() throws {
        let original = Data((0..<1024).map { UInt8($0 % 197) })
        let compressed = try compressLZ4(original)

        let decompressed = SpiceFrameRenderer.decompressLZ4FrameData(
            compressed,
            expectedSize: original.count + 16
        )

        XCTAssertNil(decompressed)
    }

    private func compressLZ4(_ data: Data) throws -> Data {
        let compressionBound = data.count + (data.count / 255) + 32
        var compressed = Data(count: max(compressionBound, 64))

        let compressedSize = compressed.withUnsafeMutableBytes { destinationBuffer -> Int in
            guard let destination = destinationBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return data.withUnsafeBytes { sourceBuffer -> Int in
                guard let source = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return Int(
                    compression_encode_buffer(
                        destination,
                        compressed.count,
                        source,
                        data.count,
                        nil,
                        COMPRESSION_LZ4
                    )
                )
            }
        }

        XCTAssertGreaterThan(compressedSize, 0, "Failed to LZ4-compress test payload")
        compressed.removeSubrange(compressedSize..<compressed.count)
        return compressed
    }
}
