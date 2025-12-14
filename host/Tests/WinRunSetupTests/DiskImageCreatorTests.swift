import WinRunShared
import XCTest

@testable import WinRunSetup

final class DiskImageCreatorTests: XCTestCase {
    // MARK: - Properties

    private var testDirectory: URL!
    private var creator: DiskImageCreator!

    // MARK: - Setup/Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Create a temporary directory for tests
        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent(
            "DiskImageCreatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )

        creator = DiskImageCreator()
    }

    override func tearDown() async throws {
        // Clean up test directory
        if let testDirectory = testDirectory,
           FileManager.default.fileExists(atPath: testDirectory.path) {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        creator = nil

        try await super.tearDown()
    }

    // MARK: - Configuration Tests

    func testDiskImageConfiguration_DefaultValues() {
        let config = DiskImageConfiguration()

        XCTAssertEqual(config.sizeGB, DiskImageConfiguration.defaultSizeGB)
        XCTAssertEqual(config.sizeGB, 64)
        XCTAssertFalse(config.overwriteExisting)
        XCTAssertTrue(config.destinationURL.path.contains("WinRun"))
        XCTAssertTrue(config.destinationURL.lastPathComponent == "windows.img")
    }

    func testDiskImageConfiguration_CustomValues() {
        let customURL = testDirectory.appendingPathComponent("custom.img")
        let config = DiskImageConfiguration(
            destinationURL: customURL,
            sizeGB: 128,
            overwriteExisting: true
        )

        XCTAssertEqual(config.destinationURL, customURL)
        XCTAssertEqual(config.sizeGB, 128)
        XCTAssertTrue(config.overwriteExisting)
    }

    func testDiskImageConfiguration_StaticConstants() {
        XCTAssertEqual(DiskImageConfiguration.defaultSizeGB, 64)
        XCTAssertEqual(DiskImageConfiguration.minimumSizeGB, 32)
        XCTAssertEqual(DiskImageConfiguration.maximumSizeGB, 2048)
        XCTAssertEqual(DiskImageConfiguration.defaultFilename, "windows.img")
    }

    func testDiskImageConfiguration_DefaultDirectory() {
        let defaultDir = DiskImageConfiguration.defaultDirectory

        // Should be in Application Support
        XCTAssertTrue(defaultDir.path.contains("Application Support"))
        XCTAssertTrue(defaultDir.path.hasSuffix("WinRun"))
    }

    // MARK: - Disk Creation Tests

    func testCreateDiskImage_CreatesSparseDisk() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB
        )

        let result = try await creator.createDiskImage(configuration: config)

        XCTAssertEqual(result.path, destination)
        XCTAssertEqual(result.sizeBytes, UInt64(DiskImageConfiguration.minimumSizeGB) * 1024 * 1024 * 1024)
        XCTAssertTrue(result.isSparse)
        // Sparse file should use minimal disk space
        XCTAssertLessThan(result.allocatedBytes, result.sizeBytes)
    }

    func testCreateDiskImage_FileExists() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB
        )

        let result = try await creator.createDiskImage(configuration: config)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path.path))
    }

    func testCreateDiskImage_CorrectFileSize() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")
        let sizeGB: UInt64 = 64
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: sizeGB
        )

        _ = try await creator.createDiskImage(configuration: config)

        // Verify the file's logical size
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = attributes[.size] as? UInt64
        XCTAssertEqual(fileSize, sizeGB * 1024 * 1024 * 1024)
    }

    func testCreateDiskImage_CreatesParentDirectory() async throws {
        let nestedPath = testDirectory
            .appendingPathComponent("nested")
            .appendingPathComponent("path")
            .appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: nestedPath,
            sizeGB: DiskImageConfiguration.minimumSizeGB
        )

        let result = try await creator.createDiskImage(configuration: config)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path.path))
    }

    // MARK: - Size Validation Tests

    func testCreateDiskImage_RejectsSizeBelowMinimum() async {
        let destination = testDirectory.appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB - 1
        )

        do {
            _ = try await creator.createDiskImage(configuration: config)
            XCTFail("Should have thrown diskInvalidSize")
        } catch let error as WinRunError {
            if case .diskInvalidSize(let sizeGB, let reason) = error {
                XCTAssertEqual(sizeGB, DiskImageConfiguration.minimumSizeGB - 1)
                XCTAssertTrue(reason.contains("Minimum"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCreateDiskImage_RejectsSizeAboveMaximum() async {
        let destination = testDirectory.appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.maximumSizeGB + 1
        )

        do {
            _ = try await creator.createDiskImage(configuration: config)
            XCTFail("Should have thrown diskInvalidSize")
        } catch let error as WinRunError {
            if case .diskInvalidSize(let sizeGB, let reason) = error {
                XCTAssertEqual(sizeGB, DiskImageConfiguration.maximumSizeGB + 1)
                XCTAssertTrue(reason.contains("Maximum"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCreateDiskImage_AcceptsMinimumSize() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB
        )

        let result = try await creator.createDiskImage(configuration: config)
        XCTAssertEqual(result.sizeBytes, UInt64(DiskImageConfiguration.minimumSizeGB) * 1024 * 1024 * 1024)
    }

    func testCreateDiskImage_AcceptsMaximumSize() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.maximumSizeGB
        )

        // This should succeed (sparse file, so actual disk usage is minimal)
        let result = try await creator.createDiskImage(configuration: config)
        XCTAssertEqual(result.sizeBytes, DiskImageConfiguration.maximumSizeGB * 1024 * 1024 * 1024)
    }

    // MARK: - Overwrite Tests

    func testCreateDiskImage_ThrowsWhenFileExists() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")

        // Create initial file
        let config1 = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB
        )
        _ = try await creator.createDiskImage(configuration: config1)

        // Try to create again without overwrite
        let config2 = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB,
            overwriteExisting: false
        )

        do {
            _ = try await creator.createDiskImage(configuration: config2)
            XCTFail("Should have thrown diskAlreadyExists")
        } catch let error as WinRunError {
            if case .diskAlreadyExists(let path) = error {
                XCTAssertEqual(path, destination.path)
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCreateDiskImage_OverwritesWhenAllowed() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")

        // Create initial file with 32GB
        let config1 = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB
        )
        _ = try await creator.createDiskImage(configuration: config1)

        // Create again with different size and overwrite
        let config2 = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: 64,
            overwriteExisting: true
        )
        let result = try await creator.createDiskImage(configuration: config2)

        XCTAssertEqual(result.sizeBytes, 64 * 1024 * 1024 * 1024)
    }

    // MARK: - Utility Method Tests

    func testDiskImageExists_ReturnsTrueForExistingFile() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB
        )
        _ = try await creator.createDiskImage(configuration: config)

        XCTAssertTrue(creator.diskImageExists(at: destination))
    }

    func testDiskImageExists_ReturnsFalseForMissingFile() {
        let destination = testDirectory.appendingPathComponent("nonexistent.img")
        XCTAssertFalse(creator.diskImageExists(at: destination))
    }

    func testDeleteDiskImage_RemovesFile() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: DiskImageConfiguration.minimumSizeGB
        )
        _ = try await creator.createDiskImage(configuration: config)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        try creator.deleteDiskImage(at: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDeleteDiskImage_SucceedsForNonexistentFile() throws {
        let destination = testDirectory.appendingPathComponent("nonexistent.img")

        // Should not throw
        XCTAssertNoThrow(try creator.deleteDiskImage(at: destination))
    }

    func testGetDiskImageInfo_ReturnsInfoForExistingDisk() async throws {
        let destination = testDirectory.appendingPathComponent("test.img")
        let sizeGB: UInt64 = 64
        let config = DiskImageConfiguration(
            destinationURL: destination,
            sizeGB: sizeGB
        )
        _ = try await creator.createDiskImage(configuration: config)

        let info = try creator.getDiskImageInfo(at: destination)

        XCTAssertNotNil(info)
        XCTAssertEqual(info?.path, destination)
        XCTAssertEqual(info?.sizeBytes, sizeGB * 1024 * 1024 * 1024)
        XCTAssertTrue(info?.isSparse ?? false)
    }

    func testGetDiskImageInfo_ReturnsNilForNonexistentFile() throws {
        let destination = testDirectory.appendingPathComponent("nonexistent.img")

        let info = try creator.getDiskImageInfo(at: destination)

        XCTAssertNil(info)
    }

    // MARK: - Error Domain Tests

    func testDiskErrors_HaveCorrectDomain() {
        let errors: [WinRunError] = [
            .diskCreationFailed(path: "/test", reason: "test"),
            .diskAlreadyExists(path: "/test"),
            .diskInvalidSize(sizeGB: 10, reason: "too small"),
            .diskInsufficientSpace(requiredGB: 100, availableGB: 10)
        ]

        for error in errors {
            XCTAssertEqual(error.domain, .setup, "Error \(error) should have setup domain")
        }
    }

    func testDiskErrors_HaveDescriptions() {
        let errors: [WinRunError] = [
            .diskCreationFailed(path: "/test", reason: "test"),
            .diskAlreadyExists(path: "/test"),
            .diskInvalidSize(sizeGB: 10, reason: "too small"),
            .diskInsufficientSpace(requiredGB: 100, availableGB: 10)
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.failureReason)
            XCTAssertNotNil(error.recoverySuggestion)
            XCTAssertFalse(error.technicalDescription.isEmpty)
        }
    }

    func testDiskErrors_HaveUniqueCodes() {
        let errors: [WinRunError] = [
            .diskCreationFailed(path: "/test", reason: "test"),
            .diskAlreadyExists(path: "/test"),
            .diskInvalidSize(sizeGB: 10, reason: "too small"),
            .diskInsufficientSpace(requiredGB: 100, availableGB: 10)
        ]

        let codes = errors.map { $0.code }
        let uniqueCodes = Set(codes)
        XCTAssertEqual(codes.count, uniqueCodes.count, "All disk errors should have unique codes")

        // Verify they're in the 7000 range (setup errors)
        for code in codes {
            XCTAssertTrue((7006...7009).contains(code), "Disk error code \(code) should be in 7006-7009 range")
        }
    }
}
