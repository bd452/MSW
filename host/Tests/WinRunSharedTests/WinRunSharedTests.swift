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
