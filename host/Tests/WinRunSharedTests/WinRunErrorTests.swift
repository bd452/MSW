import XCTest

@testable import WinRunShared

// MARK: - WinRunError Tests

final class WinRunErrorTests: XCTestCase {
    // MARK: - Domain Categorization Tests

    func testVMErrorsHaveCorrectDomain() {
        let vmErrors: [WinRunError] = [
            .vmNotInitialized,
            .vmAlreadyStopped,
            .vmOperationTimeout(operation: "start", timeoutSeconds: 60),
            .vmSnapshotFailed(reason: "disk full"),
            .virtualizationUnavailable(reason: "macOS 12"),
        ]

        for error in vmErrors {
            XCTAssertEqual(error.domain, .virtualMachine, "\(error) should be in VM domain")
        }
    }

    func testConfigErrorsHaveCorrectDomain() {
        let configErrors: [WinRunError] = [
            .configReadFailed(path: "/tmp/config.json", underlying: nil),
            .configWriteFailed(path: "/tmp/config.json", underlying: nil),
            .configInvalid(reason: "bad format"),
            .configSchemaUnsupported(found: 99, supported: 1),
            .configMissingValue(key: "cpuCount"),
        ]

        for error in configErrors {
            XCTAssertEqual(error.domain, .configuration, "\(error) should be in config domain")
        }
    }

    func testSpiceErrorsHaveCorrectDomain() {
        let spiceErrors: [WinRunError] = [
            .spiceConnectionFailed(reason: "timeout"),
            .spiceDisconnected(reason: "remote closed"),
            .spiceSharedMemoryUnavailable(reason: "not supported"),
            .spiceAuthenticationFailed(reason: "invalid token"),
        ]

        for error in spiceErrors {
            XCTAssertEqual(error.domain, .spice, "\(error) should be in spice domain")
        }
    }

    func testXPCErrorsHaveCorrectDomain() {
        let xpcErrors: [WinRunError] = [
            .daemonUnreachable,
            .xpcConnectionRejected(reason: "signature mismatch"),
            .xpcThrottled(retryAfterSeconds: 5.0),
            .xpcUnauthorized(reason: "not in staff group"),
        ]

        for error in xpcErrors {
            XCTAssertEqual(error.domain, .xpc, "\(error) should be in xpc domain")
        }
    }

    func testLauncherErrorsHaveCorrectDomain() {
        let launcherErrors: [WinRunError] = [
            .launcherAlreadyExists(path: "/Applications/Test.app"),
            .launcherCreationFailed(name: "Test", reason: "permission denied"),
            .launcherIconMissing(path: "/tmp/icon.icns"),
        ]

        for error in launcherErrors {
            XCTAssertEqual(error.domain, .launcher, "\(error) should be in launcher domain")
        }
    }

    // MARK: - LocalizedError Conformance Tests

    func testErrorDescriptionIsUserFriendly() {
        let error = WinRunError.vmNotInitialized

        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription, "Windows VM is not ready")
    }

    func testFailureReasonProvidesDetails() {
        let error = WinRunError.configSchemaUnsupported(found: 99, supported: 1)

        XCTAssertNotNil(error.failureReason)
        XCTAssertTrue(error.failureReason!.contains("99"))
        XCTAssertTrue(error.failureReason!.contains("1"))
    }

    func testRecoverySuggestionIsProvided() {
        let error = WinRunError.vmNotInitialized

        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion!.contains("winrun init"))
    }

    func testCancelledErrorHasNoRecoverySuggestion() {
        let error = WinRunError.cancelled

        XCTAssertNil(error.recoverySuggestion)
    }

    // MARK: - Error Code Tests

    func testErrorCodesAreUnique() {
        let errors: [WinRunError] = [
            .vmNotInitialized,
            .vmAlreadyStopped,
            .configReadFailed(path: "", underlying: nil),
            .configWriteFailed(path: "", underlying: nil),
            .spiceConnectionFailed(reason: ""),
            .daemonUnreachable,
            .launcherAlreadyExists(path: ""),
            .cancelled,
        ]

        var codes = Set<Int>()
        for error in errors {
            XCTAssertFalse(codes.contains(error.code), "Duplicate error code: \(error.code)")
            codes.insert(error.code)
        }
    }

    func testErrorCodesAreGroupedByDomain() {
        // VM errors: 1xxx
        XCTAssertEqual(WinRunError.vmNotInitialized.code / 1000, 1)
        XCTAssertEqual(WinRunError.vmAlreadyStopped.code / 1000, 1)

        // Config errors: 2xxx
        XCTAssertEqual(WinRunError.configReadFailed(path: "", underlying: nil).code / 1000, 2)

        // Spice errors: 3xxx
        XCTAssertEqual(WinRunError.spiceConnectionFailed(reason: "").code / 1000, 3)

        // XPC errors: 4xxx
        XCTAssertEqual(WinRunError.daemonUnreachable.code / 1000, 4)

        // Launch errors: 5xxx
        XCTAssertEqual(WinRunError.launchFailed(program: "", reason: "").code / 1000, 5)

        // Launcher errors: 6xxx
        XCTAssertEqual(WinRunError.launcherAlreadyExists(path: "").code / 1000, 6)

        // General errors: 9xxx
        XCTAssertEqual(WinRunError.cancelled.code / 1000, 9)
    }

    // MARK: - Technical Description Tests

    func testTechnicalDescriptionIncludesDomain() {
        let error = WinRunError.vmNotInitialized

        XCTAssertTrue(error.technicalDescription.contains("[vm]"))
    }

    func testTechnicalDescriptionIncludesDetails() {
        let error = WinRunError.vmOperationTimeout(operation: "start", timeoutSeconds: 60)

        XCTAssertTrue(error.technicalDescription.contains("start"))
        XCTAssertTrue(error.technicalDescription.contains("60"))
    }

    // MARK: - Error Wrapping Tests

    func testWrapPreservesWinRunError() {
        let original = WinRunError.vmNotInitialized

        let wrapped = WinRunError.wrap(original)

        XCTAssertEqual(wrapped, original)
    }

    func testWrapConvertsOtherErrorsToInternalError() {
        struct CustomError: Error {}
        let original = CustomError()

        let wrapped = WinRunError.wrap(original, context: "testing")

        if case .internalError(let message) = wrapped {
            XCTAssertTrue(message.contains("testing"))
        } else {
            XCTFail("Expected internalError")
        }
    }

    // MARK: - Equatable Tests

    func testErrorsWithSameCodeAreEqual() {
        let error1 = WinRunError.vmNotInitialized
        let error2 = WinRunError.vmNotInitialized

        XCTAssertEqual(error1, error2)
    }

    func testErrorsWithDifferentCodesAreNotEqual() {
        let error1 = WinRunError.vmNotInitialized
        let error2 = WinRunError.vmAlreadyStopped

        XCTAssertNotEqual(error1, error2)
    }
}
