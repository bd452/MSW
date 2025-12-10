import CoreGraphics
import XCTest

@testable import WinRunSpiceBridge

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
