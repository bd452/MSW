import Foundation
import WinRunShared
import XCTest

@testable import WinRunSetup

final class FloppyImageCreatorTests: XCTestCase {
    // MARK: - Properties

    private var testDirectory: URL!
    private var creator: FloppyImageCreator!

    // MARK: - Setup/Teardown

    override func setUp() async throws {
        try await super.setUp()

        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent(
            "FloppyImageCreatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )

        creator = FloppyImageCreator()
    }

    override func tearDown() async throws {
        if let testDirectory = testDirectory,
            FileManager.default.fileExists(atPath: testDirectory.path) {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        creator = nil

        try await super.tearDown()
    }

    // MARK: - Helper Methods

    private func createTestFile(named name: String, content: String = "test content") throws -> URL {
        let path = testDirectory.appendingPathComponent(name)
        try content.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - Basic Image Creation Tests

    func testCreateFloppyImage_CorrectSize() throws {
        let testFile = try createTestFile(named: "test.txt")
        let outputPath = testDirectory.appendingPathComponent("floppy.img")

        let result = try creator.createFloppyImage(
            files: ["TEST.TXT": testFile],
            at: outputPath
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        let size = attributes[.size] as? UInt64
        XCTAssertEqual(size, FloppyImageCreator.floppySize)
        XCTAssertEqual(size, 1_474_560)
    }

    func testCreateFloppyImage_HasBootSector() throws {
        let testFile = try createTestFile(named: "test.txt")
        let outputPath = testDirectory.appendingPathComponent("floppy.img")

        let result = try creator.createFloppyImage(
            files: ["TEST.TXT": testFile],
            at: outputPath
        )

        let data = try Data(contentsOf: result)

        // Check boot signature
        XCTAssertEqual(data[510], 0x55)
        XCTAssertEqual(data[511], 0xAA)

        // Check OEM name
        let oemName = String(data: data.subdata(in: 3..<11), encoding: .ascii)
        XCTAssertEqual(oemName, "WINRUN  ")

        // Check file system type
        let fsType = String(data: data.subdata(in: 54..<62), encoding: .ascii)
        XCTAssertEqual(fsType, "FAT12   ")

        // Check media type (1.44MB floppy)
        XCTAssertEqual(data[21], 0xF0)
    }

    func testCreateFloppyImage_HasValidBPB() throws {
        let testFile = try createTestFile(named: "test.txt")
        let outputPath = testDirectory.appendingPathComponent("floppy.img")

        let result = try creator.createFloppyImage(
            files: ["TEST.TXT": testFile],
            at: outputPath
        )

        let data = try Data(contentsOf: result)

        // Bytes per sector (little-endian)
        let bytesPerSector = UInt16(data[11]) | (UInt16(data[12]) << 8)
        XCTAssertEqual(bytesPerSector, 512)

        // Sectors per cluster
        XCTAssertEqual(data[13], 1)

        // Reserved sectors
        let reservedSectors = UInt16(data[14]) | (UInt16(data[15]) << 8)
        XCTAssertEqual(reservedSectors, 1)

        // Number of FATs
        XCTAssertEqual(data[16], 2)

        // Root entry count (little-endian)
        let rootEntryCount = UInt16(data[17]) | (UInt16(data[18]) << 8)
        XCTAssertEqual(rootEntryCount, 224)

        // Total sectors (little-endian)
        let totalSectors = UInt16(data[19]) | (UInt16(data[20]) << 8)
        XCTAssertEqual(totalSectors, 2880)
    }

    func testCreateFloppyImage_ContainsFileEntry() throws {
        let testFile = try createTestFile(named: "test.txt", content: "Hello, World!")
        let outputPath = testDirectory.appendingPathComponent("floppy.img")

        let result = try creator.createFloppyImage(
            files: ["TEST.TXT": testFile],
            at: outputPath
        )

        let data = try Data(contentsOf: result)

        // Root directory starts after reserved sector + 2 FAT tables
        // Reserved: 1 sector, FAT1: 9 sectors, FAT2: 9 sectors = 19 sectors
        let rootDirOffset = 19 * 512

        // First directory entry should be our file
        let entryData = data.subdata(in: rootDirOffset..<(rootDirOffset + 32))

        // Check filename (8 bytes, space-padded)
        let filename = String(data: entryData.subdata(in: 0..<8), encoding: .ascii)
        XCTAssertEqual(filename, "TEST    ")

        // Check extension (3 bytes, space-padded)
        let ext = String(data: entryData.subdata(in: 8..<11), encoding: .ascii)
        XCTAssertEqual(ext, "TXT")

        // Check file size (at offset 28, 4 bytes little-endian)
        let fileSize =
            UInt32(entryData[28]) | (UInt32(entryData[29]) << 8) | (UInt32(entryData[30]) << 16)
            | (UInt32(entryData[31]) << 24)
        XCTAssertEqual(fileSize, 13)  // "Hello, World!" is 13 bytes
    }

    func testCreateFloppyImage_MultipleFiles() throws {
        let file1 = try createTestFile(named: "file1.txt", content: "Content 1")
        let file2 = try createTestFile(named: "file2.dat", content: "Content 2")
        let outputPath = testDirectory.appendingPathComponent("floppy.img")

        let result = try creator.createFloppyImage(
            files: [
                "FILE1.TXT": file1,
                "FILE2.DAT": file2,
            ],
            at: outputPath
        )

        let data = try Data(contentsOf: result)
        let rootDirOffset = 19 * 512

        // Check first entry
        let entry1 = data.subdata(in: rootDirOffset..<(rootDirOffset + 32))
        let name1 = String(data: entry1.subdata(in: 0..<8), encoding: .ascii)
        XCTAssertEqual(name1, "FILE1   ")

        // Check second entry
        let entry2Offset = rootDirOffset + 32
        let entry2 = data.subdata(in: entry2Offset..<(entry2Offset + 32))
        let name2 = String(data: entry2.subdata(in: 0..<8), encoding: .ascii)
        XCTAssertEqual(name2, "FILE2   ")
    }

    func testCreateFloppyImage_FileNotFound() throws {
        let nonexistentFile = testDirectory.appendingPathComponent("nonexistent.txt")
        let outputPath = testDirectory.appendingPathComponent("floppy.img")

        XCTAssertThrowsError(
            try creator.createFloppyImage(
                files: ["TEST.TXT": nonexistentFile],
                at: outputPath
            )
        ) { error in
            guard case WinRunError.configInvalid(let reason) = error else {
                XCTFail("Expected configInvalid error, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("not found"))
        }
    }

    // MARK: - Autounattend Floppy Tests

    func testCreateAutounattendFloppy_Basic() throws {
        let autounattend = try createTestFile(
            named: "autounattend.xml",
            content: """
                <?xml version="1.0"?>
                <unattend xmlns="urn:schemas-microsoft-com:unattend">
                </unattend>
                """
        )

        let result = try creator.createAutounattendFloppy(autounattendPath: autounattend)

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
        let size = attributes[.size] as? UInt64
        XCTAssertEqual(size, FloppyImageCreator.floppySize)

        // Verify file is in root directory
        let data = try Data(contentsOf: result)
        let rootDirOffset = 19 * 512
        let entry = data.subdata(in: rootDirOffset..<(rootDirOffset + 32))
        let filename = String(data: entry.subdata(in: 0..<8), encoding: .ascii)
        XCTAssertEqual(filename, "AUTOUNAT")

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    func testCreateAutounattendFloppy_WithScripts() throws {
        let autounattend = try createTestFile(named: "autounattend.xml", content: "<xml/>")
        let script1 = try createTestFile(named: "provision.ps1", content: "# Script 1")
        let script2 = try createTestFile(named: "install.ps1", content: "# Script 2")

        let result = try creator.createAutounattendFloppy(
            autounattendPath: autounattend,
            provisionScripts: [script1, script2]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))

        // Verify all files are in the image
        let data = try Data(contentsOf: result)
        let rootDirOffset = 19 * 512

        // Count non-empty directory entries
        var fileCount = 0
        for index in 0..<10 {
            let entryOffset = rootDirOffset + (index * 32)
            if data[entryOffset] != 0 && data[entryOffset] != 0xE5 {
                fileCount += 1
            }
        }
        XCTAssertEqual(fileCount, 3)  // autounattend.xml + 2 scripts

        // Cleanup
        try? FileManager.default.removeItem(at: result)
    }

    func testCreateAutounattendFloppy_CustomOutputPath() throws {
        let autounattend = try createTestFile(named: "autounattend.xml", content: "<xml/>")
        let customPath = testDirectory.appendingPathComponent("custom-floppy.img")

        let result = try creator.createAutounattendFloppy(
            autounattendPath: autounattend,
            outputPath: customPath
        )

        XCTAssertEqual(result, customPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customPath.path))
    }

    // MARK: - FAT12 Structure Tests

    func testFATTable_MediaType() throws {
        let testFile = try createTestFile(named: "test.txt")
        let outputPath = testDirectory.appendingPathComponent("floppy.img")

        let result = try creator.createFloppyImage(
            files: ["TEST.TXT": testFile],
            at: outputPath
        )

        let data = try Data(contentsOf: result)

        // FAT1 starts at sector 1 (offset 512)
        let fat1Offset = 512
        XCTAssertEqual(data[fat1Offset], 0xF0)  // Media type
        XCTAssertEqual(data[fat1Offset + 1], 0xFF)  // Reserved
        XCTAssertEqual(data[fat1Offset + 2], 0xFF)  // Reserved

        // FAT2 starts at sector 10 (offset 512 * 10 = 5120)
        let fat2Offset = 512 * 10
        XCTAssertEqual(data[fat2Offset], 0xF0)
        XCTAssertEqual(data[fat2Offset + 1], 0xFF)
        XCTAssertEqual(data[fat2Offset + 2], 0xFF)
    }

    func testVolumeLabel() throws {
        let testFile = try createTestFile(named: "test.txt")
        let outputPath = testDirectory.appendingPathComponent("floppy.img")

        let result = try creator.createFloppyImage(
            files: ["TEST.TXT": testFile],
            at: outputPath
        )

        let data = try Data(contentsOf: result)

        // Volume label is at offset 43 in boot sector (11 bytes)
        let label = String(data: data.subdata(in: 43..<54), encoding: .ascii)
        XCTAssertEqual(label, "UNATTEND   ")
    }
}
