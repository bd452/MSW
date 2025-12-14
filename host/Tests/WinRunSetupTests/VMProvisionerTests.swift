import WinRunShared
import XCTest

@testable import WinRunSetup

final class VMProvisionerTests: XCTestCase {
    // MARK: - Properties

    private var testDirectory: URL!
    private var provisioner: VMProvisioner!

    // MARK: - Setup/Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Create a temporary directory for tests
        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent(
            "VMProvisionerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )

        provisioner = VMProvisioner()
    }

    override func tearDown() async throws {
        if let testDirectory = testDirectory,
           FileManager.default.fileExists(atPath: testDirectory.path) {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        provisioner = nil

        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func createTestFile(named name: String, size: Int = 1024) throws -> URL {
        let path = testDirectory.appendingPathComponent(name)
        let data = Data(repeating: 0, count: size)
        try data.write(to: path)
        return path
    }

    // MARK: - ProvisioningConfiguration Tests

    func testProvisioningConfiguration_DefaultValues() throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let config = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        XCTAssertEqual(config.cpuCount, ProvisioningConfiguration.defaultCPUCount)
        XCTAssertEqual(config.cpuCount, 4)
        XCTAssertEqual(config.memorySizeGB, ProvisioningConfiguration.defaultMemorySizeGB)
        XCTAssertEqual(config.memorySizeGB, 8)
        XCTAssertNil(config.autounattendPath)
    }

    func testProvisioningConfiguration_CustomValues() throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")
        let autounattendPath = try createTestFile(named: "autounattend.xml")

        let config = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath,
            autounattendPath: autounattendPath,
            cpuCount: 8,
            memorySizeGB: 16
        )

        XCTAssertEqual(config.isoPath, isoPath)
        XCTAssertEqual(config.diskImagePath, diskPath)
        XCTAssertEqual(config.autounattendPath, autounattendPath)
        XCTAssertEqual(config.cpuCount, 8)
        XCTAssertEqual(config.memorySizeGB, 16)
    }

    func testProvisioningConfiguration_WithDefaults() throws {
        let isoPath = try createTestFile(named: "windows.iso")

        let config = ProvisioningConfiguration.withDefaults(isoPath: isoPath)

        XCTAssertEqual(config.isoPath, isoPath)
        XCTAssertEqual(config.diskImagePath, DiskImageConfiguration.defaultPath)
        XCTAssertNil(config.autounattendPath)
    }

    // MARK: - ProvisioningStorageDevice Tests

    func testProvisioningStorageDevice_DiskDevice() throws {
        let path = try createTestFile(named: "disk.img")

        let device = ProvisioningStorageDevice(
            type: .disk,
            path: path,
            isReadOnly: false,
            isBootable: false
        )

        XCTAssertEqual(device.type, .disk)
        XCTAssertEqual(device.path, path)
        XCTAssertFalse(device.isReadOnly)
        XCTAssertFalse(device.isBootable)
    }

    func testProvisioningStorageDevice_CDROMDevice() throws {
        let path = try createTestFile(named: "windows.iso")

        let device = ProvisioningStorageDevice(
            type: .cdrom,
            path: path,
            isReadOnly: true,
            isBootable: true
        )

        XCTAssertEqual(device.type, .cdrom)
        XCTAssertTrue(device.isReadOnly)
        XCTAssertTrue(device.isBootable)
    }

    func testProvisioningStorageDevice_FloppyDevice() throws {
        let path = try createTestFile(named: "autounattend.img")

        let device = ProvisioningStorageDevice(
            type: .floppy,
            path: path,
            isReadOnly: true,
            isBootable: false
        )

        XCTAssertEqual(device.type, .floppy)
        XCTAssertTrue(device.isReadOnly)
        XCTAssertFalse(device.isBootable)
    }

    // MARK: - ProvisioningVMConfiguration Tests

    func testProvisioningVMConfiguration_MemorySizeGB() {
        let config = ProvisioningVMConfiguration(
            cpuCount: 4,
            memorySizeBytes: 8 * 1024 * 1024 * 1024,
            storageDevices: [],
            useEFIBoot: true
        )

        XCTAssertEqual(config.memorySizeGB, 8)
    }

    func testProvisioningVMConfiguration_Properties() throws {
        let diskPath = try createTestFile(named: "disk.img")
        let isoPath = try createTestFile(named: "windows.iso")

        let devices = [
            ProvisioningStorageDevice(type: .disk, path: diskPath),
            ProvisioningStorageDevice(type: .cdrom, path: isoPath, isReadOnly: true, isBootable: true)
        ]

        let config = ProvisioningVMConfiguration(
            cpuCount: 4,
            memorySizeBytes: 8 * 1024 * 1024 * 1024,
            storageDevices: devices,
            useEFIBoot: true
        )

        XCTAssertEqual(config.cpuCount, 4)
        XCTAssertEqual(config.storageDevices.count, 2)
        XCTAssertTrue(config.useEFIBoot)
    }

    // MARK: - VMProvisioner Tests

    func testCreateProvisioningConfiguration_BasicSetup() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        let vmConfig = try await provisioner.createProvisioningConfiguration(provConfig)

        XCTAssertEqual(vmConfig.cpuCount, 4)
        XCTAssertEqual(vmConfig.memorySizeGB, 8)
        XCTAssertTrue(vmConfig.useEFIBoot)

        // Should have disk and CD-ROM (no floppy without autounattend)
        XCTAssertEqual(vmConfig.storageDevices.count, 2)

        // First device should be disk
        XCTAssertEqual(vmConfig.storageDevices[0].type, .disk)
        XCTAssertEqual(vmConfig.storageDevices[0].path, diskPath)
        XCTAssertFalse(vmConfig.storageDevices[0].isReadOnly)
        XCTAssertFalse(vmConfig.storageDevices[0].isBootable)

        // Second device should be CD-ROM (ISO)
        XCTAssertEqual(vmConfig.storageDevices[1].type, .cdrom)
        XCTAssertEqual(vmConfig.storageDevices[1].path, isoPath)
        XCTAssertTrue(vmConfig.storageDevices[1].isReadOnly)
        XCTAssertTrue(vmConfig.storageDevices[1].isBootable)
    }

    func testCreateProvisioningConfiguration_WithAutounattend() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")
        let autounattendPath = try createTestFile(named: "autounattend.xml")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath,
            autounattendPath: autounattendPath
        )

        let vmConfig = try await provisioner.createProvisioningConfiguration(provConfig)

        // Should have disk, CD-ROM, and floppy
        XCTAssertEqual(vmConfig.storageDevices.count, 3)

        // Third device should be floppy
        XCTAssertEqual(vmConfig.storageDevices[2].type, .floppy)
        XCTAssertTrue(vmConfig.storageDevices[2].isReadOnly)
        XCTAssertFalse(vmConfig.storageDevices[2].isBootable)
    }

    func testCreateProvisioningConfiguration_EnforceMinimumCPU() async throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath,
            cpuCount: 1  // Below minimum
        )

        let vmConfig = try await provisioner.createProvisioningConfiguration(provConfig)

        // Should enforce minimum of 2 CPUs
        XCTAssertEqual(vmConfig.cpuCount, 2)
    }

    func testCreateProvisioningConfiguration_MissingISO() async {
        let diskPath = testDirectory.appendingPathComponent("disk.img")
        try? FileManager.default.createFile(atPath: diskPath.path, contents: Data(), attributes: nil)

        let isoPath = testDirectory.appendingPathComponent("nonexistent.iso")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        do {
            _ = try await provisioner.createProvisioningConfiguration(provConfig)
            XCTFail("Should throw error for missing ISO")
        } catch let error as WinRunError {
            if case .configInvalid(let reason) = error {
                XCTAssertTrue(reason.contains("Windows ISO"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCreateProvisioningConfiguration_MissingDisk() async {
        let isoPath = testDirectory.appendingPathComponent("windows.iso")
        try? FileManager.default.createFile(atPath: isoPath.path, contents: Data(), attributes: nil)

        let diskPath = testDirectory.appendingPathComponent("nonexistent.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath
        )

        do {
            _ = try await provisioner.createProvisioningConfiguration(provConfig)
            XCTFail("Should throw error for missing disk")
        } catch let error as WinRunError {
            if case .configInvalid(let reason) = error {
                XCTAssertTrue(reason.contains("Disk image"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Validation Tests

    func testValidateConfiguration_ValidConfig() throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath,
            cpuCount: 4,
            memorySizeGB: 8
        )

        XCTAssertNoThrow(try provisioner.validateConfiguration(provConfig))
    }

    func testValidateConfiguration_TooFewCPUs() throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath,
            cpuCount: 1,
            memorySizeGB: 8
        )

        do {
            try provisioner.validateConfiguration(provConfig)
            XCTFail("Should throw error for too few CPUs")
        } catch let error as WinRunError {
            if case .configInvalid(let reason) = error {
                XCTAssertTrue(reason.contains("CPU"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testValidateConfiguration_TooLittleMemory() throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath,
            cpuCount: 4,
            memorySizeGB: 2
        )

        do {
            try provisioner.validateConfiguration(provConfig)
            XCTFail("Should throw error for too little memory")
        } catch let error as WinRunError {
            if case .configInvalid(let reason) = error {
                XCTAssertTrue(reason.contains("Memory"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testValidateConfiguration_MissingAutounattend() throws {
        let isoPath = try createTestFile(named: "windows.iso")
        let diskPath = try createTestFile(named: "disk.img")
        let autounattendPath = testDirectory.appendingPathComponent("nonexistent.xml")

        let provConfig = ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskPath,
            autounattendPath: autounattendPath
        )

        do {
            try provisioner.validateConfiguration(provConfig)
            XCTFail("Should throw error for missing autounattend")
        } catch let error as WinRunError {
            if case .configInvalid(let reason) = error {
                XCTAssertTrue(reason.contains("Autounattend"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Bundled Resources Tests

    func testBundledAutounattendPath_NoResources() {
        let provisioner = VMProvisioner(resourcesDirectory: nil)

        XCTAssertNil(provisioner.bundledAutounattendPath())
    }

    func testBundledAutounattendPath_ResourcesNotFound() {
        let fakeResources = testDirectory.appendingPathComponent("Resources")

        let provisioner = VMProvisioner(resourcesDirectory: fakeResources)

        XCTAssertNil(provisioner.bundledAutounattendPath())
    }

    func testBundledAutounattendPath_Found() throws {
        // Create the expected path structure
        let provisionDir = testDirectory
            .appendingPathComponent("Resources")
            .appendingPathComponent("provision")
        try FileManager.default.createDirectory(at: provisionDir, withIntermediateDirectories: true)

        let autounattendPath = provisionDir.appendingPathComponent("autounattend.xml")
        try Data().write(to: autounattendPath)

        let provisioner = VMProvisioner(
            resourcesDirectory: testDirectory.appendingPathComponent("Resources")
        )

        let found = provisioner.bundledAutounattendPath()
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.lastPathComponent, "autounattend.xml")
    }
}
