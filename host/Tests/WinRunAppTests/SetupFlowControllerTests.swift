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
        let sut = SetupFlowController(
            preflight: .ready(configuration: VMConfiguration()),
            presentSetupWindow: { _ in
                XCTFail("Did not expect setup window presentation")
                return NSWindow(
                    contentRect: .zero,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
            }
        )
        var ranNormalOperation = false
 
        sut.routeToSetupOrNormalOperation {
            ranNormalOperation = true
        }
 
        XCTAssertTrue(ranNormalOperation)
    }
 
    @MainActor
    func testRoute_needsSetup_diskImageMissing_presentsWelcomeViewController() {
        let diskURL = URL(fileURLWithPath: "/tmp/winrun-missing.img")
        var presentedController: NSViewController?
        let sut = SetupFlowController(
            preflight: .needsSetup(diskImagePath: diskURL, reason: .diskImageMissing),
            presentSetupWindow: { controller in
                presentedController = controller
                return NSWindow(
                    contentRect: .zero,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
            }
        )
 
        sut.routeToSetupOrNormalOperation {
            XCTFail("Expected setup routing, not normal operation")
        }
 
        XCTAssertNotNil(presentedController)
        XCTAssertTrue(presentedController is WelcomeViewController)
    }
 
    @MainActor
    func testRoute_needsSetup_diskImageIsDirectory_presentsPlaceholderViewController() {
        let diskURL = URL(fileURLWithPath: "/tmp/winrun-directory.img")
        var presentedController: NSViewController?
        let sut = SetupFlowController(
            preflight: .needsSetup(diskImagePath: diskURL, reason: .diskImageIsDirectory),
            presentSetupWindow: { controller in
                presentedController = controller
                return NSWindow(
                    contentRect: .zero,
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: false
                )
            }
        )
 
        sut.routeToSetupOrNormalOperation {
            XCTFail("Expected setup routing, not normal operation")
        }
 
        XCTAssertNotNil(presentedController)
        let controllerTypeName = String(describing: type(of: presentedController as Any))
        XCTAssertTrue(controllerTypeName.contains("SetupPlaceholderViewController"))
    }
 
    // MARK: - Helpers
 
    private func makeTempDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("WinRunAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
 
    // Note: We intentionally avoid scanning NSApplication.shared.windows in tests to reduce flakiness.
}

