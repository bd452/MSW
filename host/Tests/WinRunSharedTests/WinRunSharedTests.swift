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

    func testProvisioningPreflightReturnsNeedsSetupWhenDiskIsMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskURL = tempDir.appendingPathComponent("windows.img")
        let configURL = tempDir.appendingPathComponent("config.json")

        let store = ConfigStore(configURL: configURL)
        try store.save(VMConfiguration(disk: VMDiskConfiguration(imagePath: diskURL, sizeGB: 64)))

        let result = ProvisioningPreflight.evaluate(configStore: store, fileManager: .default)
        XCTAssertEqual(result, .needsSetup(diskImagePath: diskURL, reason: .diskImageMissing))
    }

    func testProvisioningPreflightReturnsReadyWhenDiskExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskURL = tempDir.appendingPathComponent("windows.img")
        FileManager.default.createFile(atPath: diskURL.path, contents: Data(), attributes: nil)
        let configURL = tempDir.appendingPathComponent("config.json")

        let store = ConfigStore(configURL: configURL)
        let configuration = VMConfiguration(disk: VMDiskConfiguration(imagePath: diskURL, sizeGB: 64))
        try store.save(configuration)

        let result = ProvisioningPreflight.evaluate(configStore: store, fileManager: .default)
        XCTAssertEqual(result, .ready(configuration: configuration))
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
            guard case VMConfigurationValidationError.cpuCountOutOfRange(let actual, _) = error
            else {
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

    // MARK: - Frame Streaming Configuration Tests

    func testFrameStreamingConfigurationDefaults() {
        let config = FrameStreamingConfiguration()
        XCTAssertTrue(config.vsockEnabled)
        XCTAssertNil(config.vsockCID)
        XCTAssertEqual(config.controlPort, 5900)
        XCTAssertEqual(config.frameDataPort, 5901)
        XCTAssertTrue(config.sharedMemoryEnabled)
        XCTAssertEqual(config.sharedMemorySizeMB, 256)
        XCTAssertTrue(config.spiceConsoleEnabled)
    }

    func testFrameStreamingValidationSucceeds() throws {
        let config = FrameStreamingConfiguration()
        XCTAssertNoThrow(try config.validate())
    }

    func testFrameStreamingSharedMemoryTooSmall() {
        let config = FrameStreamingConfiguration(sharedMemorySizeMB: 8)
        XCTAssertThrowsError(try config.validate()) { error in
            guard case VMConfigurationValidationError.sharedMemoryTooSmall(let actual, let minimum) = error else {
                return XCTFail("Expected sharedMemoryTooSmall, got \(error)")
            }
            XCTAssertEqual(actual, 8)
            XCTAssertEqual(minimum, FrameStreamingConfiguration.minimumSharedMemorySizeMB)
        }
    }

    func testFrameStreamingSharedMemoryTooLarge() {
        let config = FrameStreamingConfiguration(sharedMemorySizeMB: 1024)
        XCTAssertThrowsError(try config.validate()) { error in
            guard case VMConfigurationValidationError.sharedMemoryTooLarge(let actual, let maximum) = error else {
                return XCTFail("Expected sharedMemoryTooLarge, got \(error)")
            }
            XCTAssertEqual(actual, 1024)
            XCTAssertEqual(maximum, FrameStreamingConfiguration.maximumSharedMemorySizeMB)
        }
    }

    func testFrameStreamingSharedMemoryDisabledSkipsValidation() {
        // When shared memory is disabled, size validation should be skipped
        let config = FrameStreamingConfiguration(sharedMemoryEnabled: false, sharedMemorySizeMB: 8)
        XCTAssertNoThrow(try config.validate())
    }

    func testFrameStreamingInvalidVsockPort() {
        let config = FrameStreamingConfiguration(controlPort: 0)
        XCTAssertThrowsError(try config.validate()) { error in
            guard case VMConfigurationValidationError.invalidVsockPort(let port) = error else {
                return XCTFail("Expected invalidVsockPort, got \(error)")
            }
            XCTAssertEqual(port, 0)
        }
    }

    func testFrameStreamingDuplicateVsockPort() {
        let config = FrameStreamingConfiguration(controlPort: 5900, frameDataPort: 5900)
        XCTAssertThrowsError(try config.validate()) { error in
            guard case VMConfigurationValidationError.duplicateVsockPort(let port) = error else {
                return XCTFail("Expected duplicateVsockPort, got \(error)")
            }
            XCTAssertEqual(port, 5900)
        }
    }

    func testFrameStreamingVsockDisabledSkipsPortValidation() {
        // When vsock is disabled, port validation should be skipped
        let config = FrameStreamingConfiguration(vsockEnabled: false, controlPort: 0, frameDataPort: 0)
        XCTAssertNoThrow(try config.validate())
    }

    func testVMConfigurationIncludesFrameStreaming() {
        let config = VMConfiguration()
        XCTAssertTrue(config.frameStreaming.vsockEnabled)
        XCTAssertTrue(config.frameStreaming.sharedMemoryEnabled)
        XCTAssertTrue(config.frameStreaming.spiceConsoleEnabled)
    }

    func testVMConfigurationFrameStreamingValidation() throws {
        let (baseConfig, tempDir) = try provisionedConfig()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create config with invalid frame streaming settings
        let invalidConfig = VMConfiguration(
            resources: baseConfig.resources,
            disk: baseConfig.disk,
            network: baseConfig.network,
            frameStreaming: FrameStreamingConfiguration(sharedMemorySizeMB: 8)
        )
        XCTAssertThrowsError(try invalidConfig.validate()) { error in
            guard case VMConfigurationValidationError.sharedMemoryTooSmall = error else {
                return XCTFail("Expected sharedMemoryTooSmall, got \(error)")
            }
        }
    }

    func testFrameStreamingConfigurationCodable() throws {
        let original = FrameStreamingConfiguration(
            vsockEnabled: true,
            vsockCID: 3,
            controlPort: 6000,
            frameDataPort: 6001,
            sharedMemoryEnabled: true,
            sharedMemorySizeMB: 128,
            spiceConsoleEnabled: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FrameStreamingConfiguration.self, from: data)

        XCTAssertEqual(decoded.vsockEnabled, true)
        XCTAssertEqual(decoded.vsockCID, 3)
        XCTAssertEqual(decoded.controlPort, 6000)
        XCTAssertEqual(decoded.frameDataPort, 6001)
        XCTAssertEqual(decoded.sharedMemoryEnabled, true)
        XCTAssertEqual(decoded.sharedMemorySizeMB, 128)
        XCTAssertEqual(decoded.spiceConsoleEnabled, false)
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
