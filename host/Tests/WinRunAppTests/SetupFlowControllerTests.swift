import AppKit
import Foundation
import WinRunShared
import XCTest
 
@testable import WinRunApp
 
@available(macOS 13, *)
final class SetupFlowControllerTests: XCTestCase {
    func testProvisioningPreflight_missingDiskImage_returnsNeedsSetupDiskImageMissing() throws {
        let tempDir = try makeTempDirectory()
        let configURL = tempDir.appendingPathComponent("config.json")
        let diskURL = tempDir.appendingPathComponent("windows.img")
 
        let store = ConfigStore(configURL: configURL)
        var config = VMConfiguration()
        config.diskImagePath = diskURL
        try store.save(config)
 
        let result = ProvisioningPreflight.evaluate(configStore: store, fileManager: .default)
 
        XCTAssertEqual(
            result,
            .needsSetup(diskImagePath: diskURL, reason: .diskImageMissing)
        )
    }
 
    func testProvisioningPreflight_diskImagePathIsDirectory_returnsNeedsSetupDiskImageIsDirectory() throws {
        let tempDir = try makeTempDirectory()
        let configURL = tempDir.appendingPathComponent("config.json")
        let diskURL = tempDir.appendingPathComponent("windows.img")
 
        try FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
 
        let store = ConfigStore(configURL: configURL)
        var config = VMConfiguration()
        config.diskImagePath = diskURL
        try store.save(config)
 
        let result = ProvisioningPreflight.evaluate(configStore: store, fileManager: .default)
 
        XCTAssertEqual(
            result,
            .needsSetup(diskImagePath: diskURL, reason: .diskImageIsDirectory)
        )
    }
 
    func testProvisioningPreflight_diskImageFileExists_returnsReady() throws {
        let tempDir = try makeTempDirectory()
        let configURL = tempDir.appendingPathComponent("config.json")
        let diskURL = tempDir.appendingPathComponent("windows.img")
 
        FileManager.default.createFile(atPath: diskURL.path, contents: Data())
 
        let store = ConfigStore(configURL: configURL)
        var config = VMConfiguration()
        config.diskImagePath = diskURL
        try store.save(config)
 
        let result = ProvisioningPreflight.evaluate(configStore: store, fileManager: .default)
 
        XCTAssertEqual(result, .ready(configuration: config))
    }
 
    @MainActor
    func testRoute_ready_callsNormalOperation() {
        _ = NSApplication.shared
 
        let sut = SetupFlowController(preflight: .ready(configuration: VMConfiguration()))
        var ranNormalOperation = false
 
        sut.routeToSetupOrNormalOperation {
            ranNormalOperation = true
        }
 
        XCTAssertTrue(ranNormalOperation)
    }
 
    @MainActor
    func testRoute_needsSetup_diskImageMissing_presentsWelcomeViewController() {
        _ = NSApplication.shared
 
        let diskURL = URL(fileURLWithPath: "/tmp/winrun-missing.img")
        let sut = SetupFlowController(preflight: .needsSetup(diskImagePath: diskURL, reason: .diskImageMissing))
 
        sut.routeToSetupOrNormalOperation {
            XCTFail("Expected setup routing, not normal operation")
        }
 
        let window = findLatestSetupWindow()
        XCTAssertNotNil(window)
        XCTAssertTrue(window?.contentViewController is WelcomeViewController)
        window?.close()
    }
 
    @MainActor
    func testRoute_needsSetup_diskImageIsDirectory_presentsPlaceholderViewController() {
        _ = NSApplication.shared
 
        let diskURL = URL(fileURLWithPath: "/tmp/winrun-directory.img")
        let sut = SetupFlowController(preflight: .needsSetup(diskImagePath: diskURL, reason: .diskImageIsDirectory))
 
        sut.routeToSetupOrNormalOperation {
            XCTFail("Expected setup routing, not normal operation")
        }
 
        let window = findLatestSetupWindow()
        XCTAssertNotNil(window)
 
        let controllerTypeName = String(describing: type(of: window?.contentViewController as Any))
        XCTAssertTrue(controllerTypeName.contains("SetupPlaceholderViewController"))
 
        window?.close()
    }
 
    // MARK: - Helpers
 
    private func makeTempDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("WinRunAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
 
    @MainActor
    private func findLatestSetupWindow() -> NSWindow? {
        // Prefer the window created by SetupFlowController.
        let setupWindows = NSApplication.shared.windows.filter { $0.title == "WinRun Setup" }
        return setupWindows.last
    }
}

