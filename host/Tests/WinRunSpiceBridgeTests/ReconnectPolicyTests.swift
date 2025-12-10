import XCTest

@testable import WinRunSpiceBridge

// MARK: - ReconnectPolicy Tests

final class ReconnectPolicyTests: XCTestCase {
    func testDefaultPolicyValues() {
        let policy = ReconnectPolicy()

        XCTAssertEqual(policy.initialDelay, 0.5)
        XCTAssertEqual(policy.multiplier, 1.8)
        XCTAssertEqual(policy.maxDelay, 15)
        XCTAssertEqual(policy.maxAttempts, 5)
    }

    func testDelayCalculationWithExponentialBackoff() {
        let policy = ReconnectPolicy(
            initialDelay: 1.0,
            multiplier: 2.0,
            maxDelay: 30.0
        )

        XCTAssertEqual(policy.delay(for: 1), 1.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: 2), 2.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: 3), 4.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: 4), 8.0, accuracy: 0.01)
    }

    func testDelayDoesNotExceedMaxDelay() {
        let policy = ReconnectPolicy(
            initialDelay: 1.0,
            multiplier: 10.0,
            maxDelay: 5.0
        )

        XCTAssertEqual(policy.delay(for: 1), 1.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: 2), 5.0, accuracy: 0.01)  // Would be 10, capped to 5
        XCTAssertEqual(policy.delay(for: 3), 5.0, accuracy: 0.01)  // Would be 100, capped to 5
    }

    func testDelayForZeroOrNegativeAttemptTreatedAsFirst() {
        let policy = ReconnectPolicy(initialDelay: 2.0, multiplier: 2.0)

        XCTAssertEqual(policy.delay(for: 0), 2.0, accuracy: 0.01)
        XCTAssertEqual(policy.delay(for: -1), 2.0, accuracy: 0.01)
    }
}
