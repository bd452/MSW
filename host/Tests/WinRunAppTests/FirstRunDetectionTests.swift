import Foundation
import XCTest

@testable import WinRunApp
import WinRunShared

@available(macOS 13, *)
final class FirstRunDetectionTests: XCTestCase {
    func testRequiresSetupWhenDiskImageMissing() throws {
        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskURL = tempDir.appendingPathComponent("windows.img")
        var config = VMConfiguration()
        config.diskImagePath = diskURL

        XCTAssertTrue(WinRunApplicationDelegate.requiresSetup(configuration: config))
    }

    func testRequiresSetupWhenDiskImagePathIsDirectory() throws {
        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskDirectoryURL = tempDir.appendingPathComponent("windows.img", isDirectory: true)
        try FileManager.default.createDirectory(at: diskDirectoryURL, withIntermediateDirectories: false)

        var config = VMConfiguration()
        config.diskImagePath = diskDirectoryURL

        XCTAssertTrue(WinRunApplicationDelegate.requiresSetup(configuration: config))
    }

    func testDoesNotRequireSetupWhenDiskImageExists() throws {
        let tempDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskURL = tempDir.appendingPathComponent("windows.img")
        XCTAssertTrue(FileManager.default.createFile(atPath: diskURL.path, contents: Data("test".utf8)))

        var config = VMConfiguration()
        config.diskImagePath = diskURL

        XCTAssertFalse(WinRunApplicationDelegate.requiresSetup(configuration: config))
    }
}

