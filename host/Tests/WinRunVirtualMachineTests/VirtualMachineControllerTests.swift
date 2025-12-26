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

    func testListenVsockRequiresRunningVM() async throws {
        let config = VMConfiguration()
        let controller = VirtualMachineController(configuration: config)

        do {
            _ = try controller.listenVsock(port: 5900)
            XCTFail("Expected error")
        } catch let error as VirtualMachineLifecycleError {
            XCTAssertTrue(error.description.contains("running"))
        }
    }
}
