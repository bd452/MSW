import XCTest
@testable import WinRunShared

final class WinRunSharedTests: XCTestCase {
    func testVMConfigurationDefaults() {
        let config = VMConfiguration()
        XCTAssertEqual(config.resources.cpuCount, 4)
        XCTAssertEqual(config.resources.memorySizeGB, 4)
        XCTAssertEqual(config.disk.sizeGB, 64)
        XCTAssertEqual(config.network.mode, .nat)
        XCTAssertTrue(config.diskImagePath.path.hasSuffix("WinRun/windows.img"))
    }

    func testValidationFailsWhenDiskIsMissing() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let missingDisk = tempDir.appendingPathComponent("missing.img")
        let disk = VMDiskConfiguration(imagePath: missingDisk, sizeGB: 64)
        let config = VMConfiguration(disk: disk)
        XCTAssertThrowsError(try config.validate()) { error in
            guard case VMConfigurationValidationError.diskImageMissing(let url) = error else {
                return XCTFail("Expected diskImageMissing, got \(error)")
            }
            XCTAssertEqual(url, missingDisk)
        }
    }

    func testValidationSucceedsWithProvisionedDisk() throws {
        let (config, tempDir) = try provisionedConfig()
        XCTAssertNoThrow(try config.validate())
        try FileManager.default.removeItem(at: tempDir)
    }

    func testBridgedNetworkRequiresInterfaceIdentifier() throws {
        let (baseConfig, tempDir) = try provisionedConfig()
        let bridgedConfig = VMConfiguration(
            resources: baseConfig.resources,
            disk: baseConfig.disk,
            network: VMNetworkConfiguration(mode: .bridged)
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertThrowsError(try bridgedConfig.validate()) { error in
            guard case VMConfigurationValidationError.bridgedInterfaceNotSpecified = error else {
                return XCTFail("Expected bridgedInterfaceNotSpecified, got \(error)")
            }
        }
    }

    func testCPUAndMemoryValidation() throws {
        let (baseConfig, tempDir) = try provisionedConfig()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lowCPUConfig = VMConfiguration(
            resources: VMResources(cpuCount: 1, memorySizeGB: 4),
            disk: baseConfig.disk,
            network: baseConfig.network
        )
        XCTAssertThrowsError(try lowCPUConfig.validate()) { error in
            guard case VMConfigurationValidationError.cpuCountOutOfRange(let actual, _) = error else {
                return XCTFail("Expected cpuCountOutOfRange")
            }
            XCTAssertEqual(actual, 1)
        }

        let lowMemoryConfig = VMConfiguration(
            resources: VMResources(cpuCount: 4, memorySizeGB: 2),
            disk: baseConfig.disk,
            network: baseConfig.network
        )
        XCTAssertThrowsError(try lowMemoryConfig.validate()) { error in
            guard case VMConfigurationValidationError.memoryOutOfRange(let actual, _) = error else {
                return XCTFail("Expected memoryOutOfRange")
            }
            XCTAssertEqual(actual, 2)
        }
    }

    // MARK: - Helpers

    private func provisionedConfig() throws -> (VMConfiguration, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let diskURL = tempDir.appendingPathComponent("disk.img")
        FileManager.default.createFile(atPath: diskURL.path, contents: Data(), attributes: nil)

        let disk = VMDiskConfiguration(imagePath: diskURL, sizeGB: 64)
        let config = VMConfiguration(disk: disk)
        return (config, tempDir)
    }
}

// MARK: - ConfigStore Tests

final class ConfigStoreTests: XCTestCase {
    private var tempDir: URL!
    private var configURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        configURL = tempDir.appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Load Tests

    func testLoadReturnsDefaultWhenFileDoesNotExist() throws {
        let store = ConfigStore(configURL: configURL)

        let config = try store.load()

        XCTAssertEqual(config.resources.cpuCount, 4)
        XCTAssertEqual(config.resources.memorySizeGB, 4)
    }

    func testLoadOrDefaultNeverThrows() {
        let store = ConfigStore(configURL: configURL)

        let config = store.loadOrDefault()

        XCTAssertEqual(config.resources.cpuCount, 4)
    }

    // MARK: - Save/Load Round-trip Tests

    func testSaveAndLoadRoundTrip() throws {
        let store = ConfigStore(configURL: configURL)
        let original = VMConfiguration(
            resources: VMResources(cpuCount: 8, memorySizeGB: 16),
            network: VMNetworkConfiguration(mode: .nat)
        )

        try store.save(original)
        let loaded = try store.load()

        XCTAssertEqual(loaded.resources.cpuCount, 8)
        XCTAssertEqual(loaded.resources.memorySizeGB, 16)
    }

    func testSaveCreatesDirectoryIfNeeded() throws {
        let nestedURL = tempDir
            .appendingPathComponent("nested/deep/config.json")
        let store = ConfigStore(configURL: nestedURL)

        try store.save(VMConfiguration())

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedURL.path))
    }

    func testExistsPropertyReflectsFileState() throws {
        let store = ConfigStore(configURL: configURL)

        XCTAssertFalse(store.exists)

        try store.save(VMConfiguration())

        XCTAssertTrue(store.exists)
    }

    // MARK: - Schema Version Tests

    func testSavedConfigIncludesSchemaVersion() throws {
        let store = ConfigStore(configURL: configURL)
        try store.save(VMConfiguration())

        let data = try Data(contentsOf: configURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["schemaVersion"] as? Int, VersionedConfiguration.currentSchemaVersion)
    }

    func testLoadMigratesV0ToV1() throws {
        // Write a bare VMConfiguration (v0 format - no schema version wrapper)
        let bareConfig = VMConfiguration(
            resources: VMResources(cpuCount: 6, memorySizeGB: 8)
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let data = try encoder.encode(bareConfig)
        try data.write(to: configURL)

        let store = ConfigStore(configURL: configURL)
        let loaded = try store.load()

        // Config values should be preserved
        XCTAssertEqual(loaded.resources.cpuCount, 6)
        XCTAssertEqual(loaded.resources.memorySizeGB, 8)

        // File should now have schema version
        let updatedData = try Data(contentsOf: configURL)
        let json = try JSONSerialization.jsonObject(with: updatedData) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 1)
    }

    func testLoadRejectsNewerSchemaVersion() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let futureConfig: [String: Any] = [
            "schemaVersion": 999,
            "configuration": [
                "resources": ["cpuCount": 4, "memorySizeGB": 4],
                "disk": ["imagePath": "/tmp/test.img", "sizeGB": 64],
                "network": ["mode": "nat"],
                "suspendOnIdleAfterSeconds": 300
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: futureConfig)
        try data.write(to: configURL)

        let store = ConfigStore(configURL: configURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case ConfigStoreError.unsupportedSchemaVersion(let found, let max) = error else {
                return XCTFail("Expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(max, VersionedConfiguration.currentSchemaVersion)
        }
    }

    // MARK: - Delete Tests

    func testDeleteRemovesConfigFile() throws {
        let store = ConfigStore(configURL: configURL)
        try store.save(VMConfiguration())
        XCTAssertTrue(store.exists)

        try store.delete()

        XCTAssertFalse(store.exists)
    }

    func testDeleteDoesNothingIfFileDoesNotExist() throws {
        let store = ConfigStore(configURL: configURL)

        XCTAssertNoThrow(try store.delete())
    }

    // MARK: - Initialize Defaults Tests

    func testInitializeWithDefaultsCreatesFileIfMissing() throws {
        let store = ConfigStore(configURL: configURL)

        let created = try store.initializeWithDefaultsIfNeeded()

        XCTAssertTrue(created)
        XCTAssertTrue(store.exists)
    }

    func testInitializeWithDefaultsDoesNothingIfFileExists() throws {
        let store = ConfigStore(configURL: configURL)
        try store.save(VMConfiguration(resources: VMResources(cpuCount: 8, memorySizeGB: 16)))

        let created = try store.initializeWithDefaultsIfNeeded()
        let loaded = try store.load()

        XCTAssertFalse(created)
        XCTAssertEqual(loaded.resources.cpuCount, 8) // Original values preserved
    }

    // MARK: - Error Handling Tests

    func testDecodingInvalidJSONThrowsError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "{ invalid json }".write(to: configURL, atomically: true, encoding: .utf8)

        let store = ConfigStore(configURL: configURL)

        XCTAssertThrowsError(try store.load()) { error in
            guard case ConfigStoreError.decodingFailed = error else {
                return XCTFail("Expected decodingFailed, got \(error)")
            }
        }
    }
}

// MARK: - WinRunError Tests

final class WinRunErrorTests: XCTestCase {

    // MARK: - Domain Categorization Tests

    func testVMErrorsHaveCorrectDomain() {
        let vmErrors: [WinRunError] = [
            .vmNotInitialized,
            .vmAlreadyStopped,
            .vmOperationTimeout(operation: "start", timeoutSeconds: 60),
            .vmSnapshotFailed(reason: "disk full"),
            .virtualizationUnavailable(reason: "macOS 12")
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
            .configMissingValue(key: "cpuCount")
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
            .spiceAuthenticationFailed(reason: "invalid token")
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
            .xpcUnauthorized(reason: "not in staff group")
        ]

        for error in xpcErrors {
            XCTAssertEqual(error.domain, .xpc, "\(error) should be in xpc domain")
        }
    }

    func testLauncherErrorsHaveCorrectDomain() {
        let launcherErrors: [WinRunError] = [
            .launcherAlreadyExists(path: "/Applications/Test.app"),
            .launcherCreationFailed(name: "Test", reason: "permission denied"),
            .launcherIconMissing(path: "/tmp/icon.icns")
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
            .cancelled
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
