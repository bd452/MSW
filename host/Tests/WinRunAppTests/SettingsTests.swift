import Foundation
import WinRunShared
import WinRunSpiceBridge
import XCTest

@testable import WinRunApp

@available(macOS 13, *)
final class SettingsTests: XCTestCase {
    private var tempDir: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configURL = tempDir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Settings Persistence Tests

    func testFrameBufferModeDefaultsToUncompressed() throws {
        let store = ConfigStore(configURL: configURL)
        let config = store.loadOrDefault()

        XCTAssertEqual(config.frameStreaming.frameBufferMode, .uncompressed)
    }

    func testFrameBufferModePersistsToConfigStore() throws {
        let store = ConfigStore(configURL: configURL)

        // Save config with compressed mode
        var config = VMConfiguration()
        config.frameStreaming.frameBufferMode = .compressed
        try store.save(config)

        // Load and verify
        let loaded = try store.load()
        XCTAssertEqual(loaded.frameStreaming.frameBufferMode, .compressed)
    }

    func testFrameBufferModeBackwardCompatibility() throws {
        // Create a config file without frameBufferMode (simulating old version)
        let oldConfigJSON = """
        {
            "schemaVersion": 1,
            "configuration": {
                "resources": {"cpuCount": 4, "memorySizeGB": 4},
                "disk": {"imagePath": "/tmp/test.img", "sizeGB": 64},
                "network": {"mode": "nat"},
                "frameStreaming": {
                    "vsockEnabled": true,
                    "controlPort": 5900,
                    "frameDataPort": 5901,
                    "sharedMemoryEnabled": true,
                    "sharedMemorySizeMB": 256,
                    "spiceConsoleEnabled": true
                },
                "suspendOnIdleAfterSeconds": 300
            }
        }
        """
        try oldConfigJSON.write(to: configURL, atomically: true, encoding: .utf8)

        // Load should default to uncompressed
        let store = ConfigStore(configURL: configURL)
        let config = try store.load()
        XCTAssertEqual(config.frameStreaming.frameBufferMode, .uncompressed)
    }

    func testFrameBufferModeDisplayNames() {
        XCTAssertEqual(FrameBufferMode.uncompressed.displayName, "Uncompressed (Low Latency)")
        XCTAssertEqual(FrameBufferMode.compressed.displayName, "Compressed (Lower Memory)")
    }

    func testFrameBufferModeDetailedDescriptions() {
        XCTAssertTrue(FrameBufferMode.uncompressed.detailedDescription.contains("33MB"))
        XCTAssertTrue(FrameBufferMode.compressed.detailedDescription.contains("LZ4"))
    }

    // MARK: - Settings Tab Persistence Tests

    func testSelectedTabPersistsToUserDefaults() {
        // Clear any existing value
        UserDefaults.standard.removeObject(forKey: "SettingsSelectedTab")

        // Verify default (nil if not set)
        let initialValue = UserDefaults.standard.string(forKey: "SettingsSelectedTab")
        XCTAssertNil(initialValue)

        // Set a value
        UserDefaults.standard.set(SettingsWindowController.SettingsTab.streaming.rawValue, forKey: "SettingsSelectedTab")

        // Verify persistence
        let savedValue = UserDefaults.standard.string(forKey: "SettingsSelectedTab")
        XCTAssertEqual(savedValue, "Streaming")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "SettingsSelectedTab")
    }

    // MARK: - SettingsWindowController Tests

    func testSettingsWindowControllerIsSharedSingleton() {
        let controller1 = SettingsWindowController.shared
        let controller2 = SettingsWindowController.shared

        XCTAssertTrue(controller1 === controller2)
    }

    func testSettingsWindowControllerNotVisibleInitially() {
        let controller = SettingsWindowController(
            configStore: ConfigStore(configURL: configURL)
        )

        XCTAssertFalse(controller.isVisible)
    }

    func testSettingsTabEnum() {
        // Verify all expected tabs exist
        let allTabs = SettingsWindowController.SettingsTab.allCases
        XCTAssertEqual(allTabs.count, 1) // Currently only Streaming tab

        XCTAssertTrue(allTabs.contains(.streaming))
    }

    func testSettingsTabHasIconAndToolTip() {
        let streamingTab = SettingsWindowController.SettingsTab.streaming

        XCTAssertNotNil(streamingTab.icon)
        XCTAssertFalse(streamingTab.toolTip.isEmpty)
    }
}

// MARK: - FrameBufferMode Protocol Message Tests

@available(macOS 13, *)
final class FrameBufferModeMessageTests: XCTestCase {
    func testFrameBufferModeValueConversion() {
        // Test conversion from FrameBufferMode to wire value
        let uncompressedValue = FrameBufferModeValue(from: .uncompressed)
        XCTAssertEqual(uncompressedValue.rawValue, 0)

        let compressedValue = FrameBufferModeValue(from: .compressed)
        XCTAssertEqual(compressedValue.rawValue, 1)
    }

    func testFrameBufferModeValueReverseConversion() {
        // Test conversion from wire value back to FrameBufferMode
        XCTAssertEqual(FrameBufferModeValue.uncompressed.asFrameBufferMode, .uncompressed)
        XCTAssertEqual(FrameBufferModeValue.compressed.asFrameBufferMode, .compressed)
    }

    func testConfigureStreamingMessageCreation() throws {
        let message = ConfigureStreamingSpiceMessage(
            messageId: 42,
            frameBufferMode: .compressed
        )

        XCTAssertEqual(message.messageId, 42)
        XCTAssertEqual(message.frameBufferMode, .compressed)
    }
}
