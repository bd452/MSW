import XCTest

@testable import WinRunSpiceBridge

// MARK: - Connection State Tests

final class SpiceConnectionStateTests: XCTestCase {
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
