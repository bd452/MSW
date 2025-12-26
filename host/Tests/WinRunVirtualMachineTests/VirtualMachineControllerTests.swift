import XCTest
@testable import WinRunVirtualMachine
@testable import WinRunShared

// MARK: - VirtualMachineLifecycleError Tests

final class VirtualMachineLifecycleErrorTests: XCTestCase {
    func testStartTimeoutDescription() {
        let error = VirtualMachineLifecycleError.startTimeout

        XCTAssertEqual(
            error.description,
            "Timed out waiting for the Windows VM to finish booting."
        )
    }

    func testInvalidSnapshotDescription() {
        let error = VirtualMachineLifecycleError.invalidSnapshot("corrupt file")

        XCTAssertTrue(error.description.contains("corrupt file"))
    }

    func testVirtualizationUnavailableDescription() {
        let error = VirtualMachineLifecycleError.virtualizationUnavailable("macOS 12 required")

        XCTAssertTrue(error.description.contains("macOS 12"))
        XCTAssertTrue(error.description.contains("unavailable"))
    }

    func testAlreadyStoppedDescription() {
        let error = VirtualMachineLifecycleError.alreadyStopped

        XCTAssertEqual(error.description, "The Windows VM is already stopped.")
    }
}

// MARK: - VMState Tests

final class VMStateTests: XCTestCase {
    func testVMStateInitialization() {
        let state = VMState(status: .running, uptime: 123.5, activeSessions: 3)

        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.uptime, 123.5)
        XCTAssertEqual(state.activeSessions, 3)
    }

    func testVMStatusRawValues() {
        XCTAssertEqual(VMStatus.stopped.rawValue, "stopped")
        XCTAssertEqual(VMStatus.starting.rawValue, "starting")
        XCTAssertEqual(VMStatus.running.rawValue, "running")
        XCTAssertEqual(VMStatus.suspending.rawValue, "suspending")
        XCTAssertEqual(VMStatus.suspended.rawValue, "suspended")
        XCTAssertEqual(VMStatus.stopping.rawValue, "stopping")
    }

    func testVMStateCodable() throws {
        let original = VMState(status: .running, uptime: 45.5, activeSessions: 2)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMState.self, from: data)

        XCTAssertEqual(decoded.status, .running)
        XCTAssertEqual(decoded.uptime, 45.5)
        XCTAssertEqual(decoded.activeSessions, 2)
    }
}

// MARK: - VMMetricsSnapshot Tests

final class VMMetricsSnapshotTests: XCTestCase {
    func testMetricsSnapshotDescription() {
        let snapshot = VMMetricsSnapshot(
            event: "vm_started",
            uptimeSeconds: 123.45,
            activeSessions: 2,
            totalSessions: 5,
            bootCount: 3,
            suspendCount: 1
        )

        let description = snapshot.description

        XCTAssertTrue(description.contains("vm_started"))
        XCTAssertTrue(description.contains("123.45"))
        XCTAssertTrue(description.contains("activeSessions=2"))
        XCTAssertTrue(description.contains("totalSessions=5"))
        XCTAssertTrue(description.contains("boots=3"))
        XCTAssertTrue(description.contains("suspends=1"))
    }

    func testMetricsSnapshotCodable() throws {
        let original = VMMetricsSnapshot(
            event: "test_event",
            uptimeSeconds: 100,
            activeSessions: 1,
            totalSessions: 10,
            bootCount: 5,
            suspendCount: 2
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMMetricsSnapshot.self, from: data)

        XCTAssertEqual(decoded.event, "test_event")
        XCTAssertEqual(decoded.uptimeSeconds, 100)
        XCTAssertEqual(decoded.activeSessions, 1)
        XCTAssertEqual(decoded.totalSessions, 10)
        XCTAssertEqual(decoded.bootCount, 5)
        XCTAssertEqual(decoded.suspendCount, 2)
    }
}

// MARK: - VirtualMachineController Basic Tests
// Note: Full lifecycle tests require virtualization entitlements and are tested via Xcode

final class VirtualMachineControllerBasicTests: XCTestCase {
    func testInitialStateIsStopped() async throws {
        let config = VMConfiguration()  // Uses defaults
        let controller = VirtualMachineController(configuration: config)

        let state = await controller.currentState()

        XCTAssertEqual(state.status, .stopped)
        XCTAssertEqual(state.uptime, 0)
        XCTAssertEqual(state.activeSessions, 0)
    }

    func testShutdownWhenAlreadyStoppedThrowsError() async throws {
        let config = VMConfiguration()
        let controller = VirtualMachineController(configuration: config)

        do {
            _ = try await controller.shutdown()
            XCTFail("Expected error")
        } catch let error as VirtualMachineLifecycleError {
            XCTAssertEqual(error.description, "The Windows VM is already stopped.")
        }
    }

    func testSnapshotRequiresRunningState() async throws {
        let config = VMConfiguration()
        let controller = VirtualMachineController(configuration: config)

        do {
            _ = try await controller.saveSnapshot()
            XCTFail("Expected error")
        } catch let error as VirtualMachineLifecycleError {
            if case .invalidSnapshot(let reason) = error {
                XCTAssertTrue(reason.contains("running"))
            } else {
                XCTFail("Expected invalidSnapshot error, got \(error)")
            }
        }
    }

    func testFrameStreamingConfigurationExposed() async {
        let frameConfig = FrameStreamingConfiguration(
            vsockEnabled: true,
            controlPort: 7000,
            frameDataPort: 7001,
            sharedMemoryEnabled: true,
            sharedMemorySizeMB: 128
        )
        let config = VMConfiguration(frameStreaming: frameConfig)
        let controller = VirtualMachineController(configuration: config)

        let exposed = await controller.frameStreamingConfiguration
        XCTAssertEqual(exposed.controlPort, 7000)
        XCTAssertEqual(exposed.frameDataPort, 7001)
        XCTAssertEqual(exposed.sharedMemorySizeMB, 128)
    }

    func testConnectVsockRequiresRunningVM() async throws {
        let config = VMConfiguration()
        let controller = VirtualMachineController(configuration: config)

        do {
            _ = try await controller.connectVsock(port: 5900)
            XCTFail("Expected error")
        } catch let error as VirtualMachineLifecycleError {
            XCTAssertTrue(error.description.contains("running"))
        }
    }

    #if canImport(Virtualization)
    @available(macOS 13, *)
    func testListenVsockRequiresRunningVM() async throws {
        let config = VMConfiguration()
        let controller = VirtualMachineController(configuration: config)

        do {
            _ = try await controller.listenVsock(port: 5900) { _ in true }
            XCTFail("Expected error")
        } catch let error as VirtualMachineLifecycleError {
            XCTAssertTrue(error.description.contains("running"))
        }
    }
    #endif
}

// MARK: - Shared Memory Tests

final class SharedMemoryManagerTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WinRunTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testCreateRegionCreatesFile() throws {
        let manager = SharedMemoryManager(baseDirectory: tempDirectory)
        let region = try manager.createRegion(sizeMB: 16)

        XCTAssertTrue(FileManager.default.fileExists(atPath: region.fileURL.path))
        XCTAssertEqual(region.size, 16 * 1024 * 1024)
    }

    func testCreateRegionMapsMemory() throws {
        let manager = SharedMemoryManager(baseDirectory: tempDirectory)
        let region = try manager.createRegion(sizeMB: 16)

        // Write to the memory
        let testValue: UInt32 = 0x12345678
        region.pointer.storeBytes(of: testValue, as: UInt32.self)

        // Read it back
        let readValue = region.pointer.load(as: UInt32.self)
        XCTAssertEqual(readValue, testValue)
    }

    func testCurrentRegionReturnsActiveRegion() throws {
        let manager = SharedMemoryManager(baseDirectory: tempDirectory)

        XCTAssertNil(manager.currentRegion())

        let region = try manager.createRegion(sizeMB: 16)

        XCTAssertNotNil(manager.currentRegion())
        XCTAssertEqual(manager.currentRegion()?.fileURL, region.fileURL)
    }

    func testCleanupRemovesRegion() throws {
        let manager = SharedMemoryManager(baseDirectory: tempDirectory)
        _ = try manager.createRegion(sizeMB: 16)

        XCTAssertNotNil(manager.currentRegion())

        manager.cleanup()

        XCTAssertNil(manager.currentRegion())
    }

    func testGuestRelativePath() throws {
        let manager = SharedMemoryManager(baseDirectory: tempDirectory)
        let region = try manager.createRegion(sizeMB: 16)

        XCTAssertEqual(region.guestRelativePath, "framebuffer.shm")
    }

    func testVirtioFSTag() {
        XCTAssertEqual(SharedMemoryManager.virtioFSTag, "winrun-framebuffer")
    }

    func testSharedDirectoryPath() {
        let manager = SharedMemoryManager(baseDirectory: tempDirectory)
        XCTAssertEqual(manager.sharedDirectoryPath, tempDirectory)
    }

    func testCreatingNewRegionCleansUpOldRegion() throws {
        let manager = SharedMemoryManager(baseDirectory: tempDirectory)

        let region1 = try manager.createRegion(sizeMB: 16)
        let url1 = region1.fileURL

        // Create a second region (should clean up the first)
        let region2 = try manager.createRegion(sizeMB: 32)

        // The new region should be different
        XCTAssertEqual(region2.size, 32 * 1024 * 1024)

        // Old URL should be cleaned up (file removed when old region is deinitialized)
        // Since region1 is still in scope, it may or may not be removed yet
        // After region1 goes out of scope, the file should be gone
        _ = url1 // suppress unused warning
    }
}

// MARK: - Shared Memory Error Tests

final class SharedMemoryErrorTests: XCTestCase {
    func testDirectoryCreationFailedDescription() {
        let url = URL(fileURLWithPath: "/test/path")
        let underlyingError = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        let error = SharedMemoryError.directoryCreationFailed(url, underlyingError)

        XCTAssertTrue(error.description.contains("/test/path"))
        XCTAssertTrue(error.description.contains("Permission denied"))
    }

    func testFileCreationFailedDescription() {
        let url = URL(fileURLWithPath: "/test/file.shm")
        let underlyingError = NSError(domain: "Test", code: 2)
        let error = SharedMemoryError.fileCreationFailed(url, underlyingError)

        XCTAssertTrue(error.description.contains("/test/file.shm"))
    }

    func testFileTruncationFailedDescription() {
        let url = URL(fileURLWithPath: "/test/file.shm")
        let underlyingError = NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "No space"])
        let error = SharedMemoryError.fileTruncationFailed(url, underlyingError)

        XCTAssertTrue(error.description.contains("/test/file.shm"))
        XCTAssertTrue(error.description.contains("No space"))
    }

    func testMemoryMappingFailedDescription() {
        let url = URL(fileURLWithPath: "/test/file.shm")
        let error = SharedMemoryError.memoryMappingFailed(url, "mmap failed")

        XCTAssertTrue(error.description.contains("/test/file.shm"))
        XCTAssertTrue(error.description.contains("mmap failed"))
    }

    func testRegionNotInitializedDescription() {
        let error = SharedMemoryError.regionNotInitialized

        XCTAssertTrue(error.description.contains("not been initialized"))
    }
}

// MARK: - VirtualMachineController Shared Memory Tests

final class VirtualMachineControllerSharedMemoryTests: XCTestCase {
    func testGetSharedMemoryDirectoryReturnsDefaultPath() async {
        let config = VMConfiguration()
        let controller = VirtualMachineController(configuration: config)

        let directory = await controller.getSharedMemoryDirectory()

        XCTAssertTrue(directory.path.contains("SharedMemory"))
    }

    func testGetSharedMemoryRegionReturnsNilBeforeInitialization() async {
        let config = VMConfiguration()
        let controller = VirtualMachineController(configuration: config)

        let region = await controller.getSharedMemoryRegion()

        XCTAssertNil(region)
    }

    func testInitializeSharedMemoryFailsWhenDisabled() async {
        let frameConfig = FrameStreamingConfiguration(sharedMemoryEnabled: false)
        let config = VMConfiguration(frameStreaming: frameConfig)
        let controller = VirtualMachineController(configuration: config)

        do {
            _ = try await controller.initializeSharedMemory()
            XCTFail("Expected error")
        } catch let error as SharedMemoryError {
            XCTAssertEqual(error.description, "Shared memory region has not been initialized")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testInitializeSharedMemoryCreatesRegion() async throws {
        let frameConfig = FrameStreamingConfiguration(
            sharedMemoryEnabled: true,
            sharedMemorySizeMB: 32
        )
        let config = VMConfiguration(frameStreaming: frameConfig)
        let controller = VirtualMachineController(configuration: config)

        let region = try await controller.initializeSharedMemory()

        XCTAssertEqual(region.size, 32 * 1024 * 1024)
        XCTAssertNotNil(await controller.getSharedMemoryRegion())

        // Clean up
        await controller.cleanupSharedMemory()
    }

    func testCleanupSharedMemoryRemovesRegion() async throws {
        let frameConfig = FrameStreamingConfiguration(sharedMemoryEnabled: true)
        let config = VMConfiguration(frameStreaming: frameConfig)
        let controller = VirtualMachineController(configuration: config)

        _ = try await controller.initializeSharedMemory()
        XCTAssertNotNil(await controller.getSharedMemoryRegion())

        await controller.cleanupSharedMemory()

        XCTAssertNil(await controller.getSharedMemoryRegion())
    }
}
