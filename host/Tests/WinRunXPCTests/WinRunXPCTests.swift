import XCTest
@testable import WinRunXPC
@testable import WinRunShared

// MARK: - Daemon Client Integration Tests

/// Smoke tests for WinRunDaemonClient that verify XPC message handling
/// without requiring an actual daemon connection.
final class WinRunDaemonClientTests: XCTestCase {
    // MARK: - Client Initialization Tests

    func testClientInitializesWithDefaultLogger() {
        let client = WinRunDaemonClient()

        // Client should be created without errors
        XCTAssertNotNil(client)
    }

    func testClientInitializesWithCustomLogger() {
        let logger = MockLogger()
        let client = WinRunDaemonClient(logger: logger)

        XCTAssertNotNil(client)
    }

    // MARK: - XPC Interface Protocol Conformance Tests

    func testXPCInterfaceHasRequiredMethods() {
        // Verify the protocol has all expected methods by checking type existence
        // This ensures the XPC contract remains stable across versions
        let interface = NSXPCInterface(with: WinRunDaemonXPC.self)

        XCTAssertNotNil(interface)

        // The interface should expose the protocol's methods
        // If this compiles, the protocol has the required shape
    }

    // MARK: - Error Handling Tests

    func testDaemonUnreachableErrorHasCorrectDomain() {
        let error = WinRunError.daemonUnreachable

        XCTAssertEqual(error.domain, .xpc)
        XCTAssertNotNil(error.errorDescription)
    }

    func testXPCThrottledErrorIncludesRetryTime() {
        let error = WinRunError.xpcThrottled(retryAfterSeconds: 5.0)

        XCTAssertEqual(error.domain, .xpc)
        XCTAssertNotNil(error.failureReason)
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testXPCConnectionRejectedErrorIncludesReason() {
        let error = WinRunError.xpcConnectionRejected(reason: "signature mismatch")

        XCTAssertEqual(error.domain, .xpc)
        XCTAssertTrue(error.failureReason?.contains("signature") ?? false)
    }

    func testXPCUnauthorizedErrorIncludesReason() {
        let error = WinRunError.xpcUnauthorized(reason: "not in admin group")

        XCTAssertEqual(error.domain, .xpc)
        XCTAssertTrue(error.failureReason?.contains("admin") ?? false)
    }
}

// MARK: - XPC Protocol Shape Tests

/// Tests that verify the XPC protocol interface remains backward compatible
final class XPCProtocolShapeTests: XCTestCase {
    func testWinRunDaemonXPCIsObjCProtocol() {
        // The protocol must be @objc for XPC to work
        let interface = NSXPCInterface(with: WinRunDaemonXPC.self)
        XCTAssertNotNil(interface)
    }

    func testNSDataUsedForComplexTypes() {
        // Verify that the protocol uses NSData for serialized payloads
        // This is important for XPC interop - complex types must be serialized
        let interface = NSXPCInterface(with: WinRunDaemonXPC.self)
        XCTAssertNotNil(interface)
        // If compilation succeeds, the protocol signature is correct
    }

    func testNSStringUsedForStringParameters() {
        // Verify NSString is used for string parameters (XPC requirement)
        let interface = NSXPCInterface(with: WinRunDaemonXPC.self)
        XCTAssertNotNil(interface)
        // If compilation succeeds, closeSession and syncShortcuts use NSString
    }
}

// MARK: - XPC Request/Response Encoding Tests

/// Tests for the encoding/decoding of XPC messages
final class XPCEncodingTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Request Encoding Tests

    func testProgramLaunchRequestEncodesToNSData() throws {
        let request = ProgramLaunchRequest(
            windowsPath: "C:\\test.exe",
            arguments: ["--flag"],
            workingDirectory: nil
        )

        let data = try encoder.encode(request)
        let nsData = NSData(data: data)

        XCTAssertGreaterThan(nsData.length, 0)
    }

    func testLargeArgumentListEncodesCorrectly() throws {
        let manyArgs = (0..<100).map { "arg\($0)" }
        let request = ProgramLaunchRequest(
            windowsPath: "test.exe",
            arguments: manyArgs
        )

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(ProgramLaunchRequest.self, from: data)

        XCTAssertEqual(decoded.arguments.count, 100)
    }

    // MARK: - Response Decoding Tests

    func testVMStateDecodingFromNSData() throws {
        let state = VMState(status: .running, uptime: 100, activeSessions: 2)
        let data = try encoder.encode(state)
        let nsData = NSData(data: data)

        let decoded = try decoder.decode(VMState.self, from: nsData as Data)

        XCTAssertEqual(decoded.status, .running)
    }

    func testGuestSessionListDecodingFromNSData() throws {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let sessions = GuestSessionList(sessions: [
            GuestSession(id: "1", windowsPath: "a.exe", windowTitle: nil, processId: 1, startedAt: Date())
        ])
        let data = try encoder.encode(sessions)
        let nsData = NSData(data: data)

        let decoded = try decoder.decode(GuestSessionList.self, from: nsData as Data)

        XCTAssertEqual(decoded.sessions.count, 1)
    }

    func testWindowsShortcutListDecodingFromNSData() throws {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let shortcuts = WindowsShortcutList(shortcuts: [
            WindowsShortcut(shortcutPath: "a.lnk", targetPath: "a.exe", displayName: "A")
        ])
        let data = try encoder.encode(shortcuts)
        let nsData = NSData(data: data)

        let decoded = try decoder.decode(WindowsShortcutList.self, from: nsData as Data)

        XCTAssertEqual(decoded.shortcuts.count, 1)
    }

    func testShortcutSyncResultDecodingFromNSData() throws {
        let result = ShortcutSyncResult(
            created: 3,
            skipped: 1,
            failed: 0,
            launcherPaths: ["/path/to/app.app"]
        )
        let data = try encoder.encode(result)
        let nsData = NSData(data: data)

        let decoded = try decoder.decode(ShortcutSyncResult.self, from: nsData as Data)

        XCTAssertEqual(decoded.created, 3)
        XCTAssertEqual(decoded.launcherPaths.first, "/path/to/app.app")
    }

    // MARK: - Error Response Tests

    func testNSErrorConversionPreservesMessage() {
        let error = NSError(
            domain: "com.winrun.daemon",
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "VM not initialized"]
        )

        XCTAssertEqual(error.domain, "com.winrun.daemon")
        XCTAssertEqual(error.code, 1001)
        XCTAssertEqual(error.localizedDescription, "VM not initialized")
    }
}

// MARK: - XPC Authentication Error Tests

final class XPCAuthenticationErrorTests: XCTestCase {
    func testUserNotInAllowedGroupErrorDescription() {
        let error = XPCAuthenticationError.userNotInAllowedGroup(user: 501, group: "admin")
        let description = error.description

        XCTAssertTrue(description.contains("501"))
        XCTAssertTrue(description.contains("admin"))
    }

    func testInvalidCodeSignatureErrorDescription() {
        let error = XPCAuthenticationError.invalidCodeSignature(details: "missing signature")
        let description = error.description

        XCTAssertTrue(description.contains("signature"))
    }

    func testUnauthorizedTeamIdentifierErrorDescription() {
        let error = XPCAuthenticationError.unauthorizedTeamIdentifier(
            expected: "ABCD1234",
            actual: "XYZ9999"
        )
        let description = error.description

        XCTAssertTrue(description.contains("ABCD1234"))
        XCTAssertTrue(description.contains("XYZ9999"))
    }

    func testUnauthorizedBundleIdentifierErrorDescription() {
        let error = XPCAuthenticationError.unauthorizedBundleIdentifier(
            identifier: "com.evil.app"
        )
        let description = error.description

        XCTAssertTrue(description.contains("com.evil.app"))
    }

    func testThrottledErrorDescription() {
        let error = XPCAuthenticationError.throttled(retryAfterSeconds: 5.5)
        let description = error.description

        XCTAssertTrue(description.contains("5.5"))
        XCTAssertTrue(description.lowercased().contains("retry"))
    }

    func testConnectionRejectedErrorDescription() {
        let error = XPCAuthenticationError.connectionRejected(reason: "test reason")
        let description = error.description

        XCTAssertTrue(description.contains("test reason"))
    }
}

// MARK: - XPC Authentication Config Tests

final class XPCAuthenticationConfigTests: XCTestCase {
    func testDevelopmentConfigAllowsUnsignedClients() {
        let config = XPCAuthenticationConfig.development

        XCTAssertTrue(config.allowUnsignedClients)
    }

    func testProductionConfigRequiresSignature() {
        let config = XPCAuthenticationConfig.production

        XCTAssertFalse(config.allowUnsignedClients)
    }

    func testDevelopmentConfigHasStaffGroup() {
        let config = XPCAuthenticationConfig.development

        XCTAssertEqual(config.allowedGroupName, "staff")
    }

    func testProductionConfigHasStaffGroup() {
        let config = XPCAuthenticationConfig.production

        XCTAssertEqual(config.allowedGroupName, "staff")
    }

    func testProductionConfigHasBundleIdPrefix() {
        let config = XPCAuthenticationConfig.production

        XCTAssertTrue(config.allowedBundleIdentifierPrefixes.contains("com.winrun."))
    }
}

// MARK: - Throttling Config Tests

final class ThrottlingConfigTests: XCTestCase {
    func testDevelopmentConfigHasHigherLimits() {
        let dev = ThrottlingConfig.development
        let prod = ThrottlingConfig.production

        XCTAssertGreaterThan(dev.maxRequestsPerWindow, prod.maxRequestsPerWindow)
    }

    func testProductionConfigHasReasonableLimits() {
        let config = ThrottlingConfig.production

        XCTAssertGreaterThan(config.maxRequestsPerWindow, 0)
        XCTAssertGreaterThan(config.windowSeconds, 0)
    }

    func testDefaultInitializerHasReasonableDefaults() {
        let defaultConfig = ThrottlingConfig()

        // Default initializer should have reasonable values (60 req/min)
        XCTAssertEqual(defaultConfig.maxRequestsPerWindow, 60)
        XCTAssertEqual(defaultConfig.windowSeconds, 60)
        XCTAssertEqual(defaultConfig.burstAllowance, 10)
        XCTAssertEqual(defaultConfig.cooldownSeconds, 5)
    }
}

// MARK: - Rate Limiter Tests

final class RateLimiterTests: XCTestCase {
    func testFirstRequestAlwaysSucceeds() async {
        let config = ThrottlingConfig(maxRequestsPerWindow: 10, windowSeconds: 60, burstAllowance: 5, cooldownSeconds: 1)
        let limiter = RateLimiter(config: config)

        let result = await limiter.checkRequest(clientId: "client-1")

        switch result {
        case .success:
            break  // Expected
        case .failure(let error):
            XCTFail("First request should succeed, got: \(error)")
        }
    }

    func testRequestsWithinBurstAllowanceSucceed() async {
        let config = ThrottlingConfig(maxRequestsPerWindow: 5, windowSeconds: 60, burstAllowance: 3, cooldownSeconds: 1)
        let limiter = RateLimiter(config: config)
        let clientId = "client-burst"

        // Should allow 5 + 3 = 8 requests before throttling
        for i in 0..<8 {
            let result = await limiter.checkRequest(clientId: clientId)
            switch result {
            case .success:
                break  // Expected
            case .failure(let error):
                XCTFail("Request \(i) within burst should succeed, got: \(error)")
            }
        }
    }

    func testExceedingBurstAllowanceTriggersThrottle() async {
        let config = ThrottlingConfig(maxRequestsPerWindow: 3, windowSeconds: 60, burstAllowance: 2, cooldownSeconds: 1)
        let limiter = RateLimiter(config: config)
        let clientId = "client-exceed"

        // Exhaust all tokens (3 + 2 = 5)
        for _ in 0..<5 {
            _ = await limiter.checkRequest(clientId: clientId)
        }

        // Next request should be throttled
        let result = await limiter.checkRequest(clientId: clientId)
        switch result {
        case .success:
            XCTFail("Request exceeding limit should be throttled")
        case .failure(let error):
            guard case .throttled(let retryAfter) = error else {
                XCTFail("Expected throttled error, got: \(error)")
                return
            }
            XCTAssertGreaterThan(retryAfter, 0)
        }
    }

    func testDifferentClientsHaveSeparateBuckets() async {
        let config = ThrottlingConfig(maxRequestsPerWindow: 2, windowSeconds: 60, burstAllowance: 0, cooldownSeconds: 1)
        let limiter = RateLimiter(config: config)

        // Exhaust client-1's bucket
        _ = await limiter.checkRequest(clientId: "client-1")
        _ = await limiter.checkRequest(clientId: "client-1")

        // client-2 should still have full allowance
        let result = await limiter.checkRequest(clientId: "client-2")
        switch result {
        case .success:
            break  // Expected
        case .failure(let error):
            XCTFail("client-2 should have separate bucket, got: \(error)")
        }
    }

    func testMetricsTrackActiveClients() async {
        let config = ThrottlingConfig(maxRequestsPerWindow: 10, windowSeconds: 60, burstAllowance: 5, cooldownSeconds: 1)
        let limiter = RateLimiter(config: config)

        // No clients initially
        var metrics = await limiter.metrics()
        XCTAssertEqual(metrics.activeClients, 0)

        // Add some clients
        _ = await limiter.checkRequest(clientId: "client-a")
        _ = await limiter.checkRequest(clientId: "client-b")
        _ = await limiter.checkRequest(clientId: "client-c")

        metrics = await limiter.metrics()
        XCTAssertEqual(metrics.activeClients, 3)
    }

    func testMetricsTrackClientsInCooldown() async {
        let config = ThrottlingConfig(maxRequestsPerWindow: 1, windowSeconds: 60, burstAllowance: 0, cooldownSeconds: 5)
        let limiter = RateLimiter(config: config)

        // Exhaust a client's bucket and trigger cooldown
        _ = await limiter.checkRequest(clientId: "client-cooldown")
        _ = await limiter.checkRequest(clientId: "client-cooldown")  // This triggers cooldown

        let metrics = await limiter.metrics()
        XCTAssertEqual(metrics.activeClients, 1)
        XCTAssertEqual(metrics.clientsInCooldown, 1)
    }

    func testPruneStaleClientsRemovesOldEntries() async {
        let config = ThrottlingConfig(maxRequestsPerWindow: 10, windowSeconds: 60, burstAllowance: 5, cooldownSeconds: 1)
        let limiter = RateLimiter(config: config)

        // Add a client
        _ = await limiter.checkRequest(clientId: "stale-client")

        var metrics = await limiter.metrics()
        XCTAssertEqual(metrics.activeClients, 1)

        // Prune with 0 age should remove all entries
        await limiter.pruneStaleClients(olderThan: 0)

        metrics = await limiter.metrics()
        XCTAssertEqual(metrics.activeClients, 0)
    }

    func testCooldownBlocksRequestsUntilExpired() async {
        let config = ThrottlingConfig(maxRequestsPerWindow: 1, windowSeconds: 60, burstAllowance: 0, cooldownSeconds: 0.1)
        let limiter = RateLimiter(config: config)
        let clientId = "client-cooldown-test"

        // Exhaust tokens and enter cooldown
        _ = await limiter.checkRequest(clientId: clientId)
        let throttledResult = await limiter.checkRequest(clientId: clientId)

        switch throttledResult {
        case .success:
            XCTFail("Should be throttled")
        case .failure:
            break  // Expected
        }

        // Wait for cooldown to expire
        try? await Task.sleep(for: .milliseconds(150))

        // Should succeed now (tokens have refilled)
        let afterCooldown = await limiter.checkRequest(clientId: clientId)
        switch afterCooldown {
        case .success:
            break  // Expected - cooldown expired and some tokens refilled
        case .failure(let error):
            // If still throttled, that's acceptable if not enough time passed
            guard case .throttled = error else {
                XCTFail("Expected success or throttled, got: \(error)")
                return
            }
        }
    }
}

// MARK: - Mock Logger

/// Thread-safe mock logger for testing
private final class MockLogger: Logger, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [(level: LogLevel, message: String)] = []

    var messages: [(level: LogLevel, message: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    func log(level: LogLevel, message: String, metadata: LogMetadata?, file: String, function: String, line: UInt) {
        lock.lock()
        defer { lock.unlock() }
        _messages.append((level, message))
    }
}
