import WinRunShared
import XCTest

@testable import WinRunSetup

final class ProvisioningStateTests: XCTestCase {
    // MARK: - ProvisioningPhase Tests

    func testProvisioningPhase_DisplayNames() {
        XCTAssertEqual(ProvisioningPhase.idle.displayName, "Ready to start")
        XCTAssertEqual(ProvisioningPhase.validatingISO.displayName, "Validating Windows ISO")
        XCTAssertEqual(ProvisioningPhase.creatingDisk.displayName, "Creating disk image")
        XCTAssertEqual(ProvisioningPhase.installingWindows.displayName, "Installing Windows")
        XCTAssertEqual(ProvisioningPhase.postInstallProvisioning.displayName, "Configuring Windows")
        XCTAssertEqual(ProvisioningPhase.creatingSnapshot.displayName, "Finalizing")
        XCTAssertEqual(ProvisioningPhase.complete.displayName, "Setup complete")
        XCTAssertEqual(ProvisioningPhase.failed.displayName, "Setup failed")
        XCTAssertEqual(ProvisioningPhase.cancelled.displayName, "Setup cancelled")
    }

    func testProvisioningPhase_TerminalStates() {
        XCTAssertFalse(ProvisioningPhase.idle.isTerminal)
        XCTAssertFalse(ProvisioningPhase.validatingISO.isTerminal)
        XCTAssertFalse(ProvisioningPhase.creatingDisk.isTerminal)
        XCTAssertFalse(ProvisioningPhase.installingWindows.isTerminal)
        XCTAssertFalse(ProvisioningPhase.postInstallProvisioning.isTerminal)
        XCTAssertFalse(ProvisioningPhase.creatingSnapshot.isTerminal)

        XCTAssertTrue(ProvisioningPhase.complete.isTerminal)
        XCTAssertTrue(ProvisioningPhase.failed.isTerminal)
        XCTAssertTrue(ProvisioningPhase.cancelled.isTerminal)
    }

    func testProvisioningPhase_ActiveStates() {
        XCTAssertFalse(ProvisioningPhase.idle.isActive)
        XCTAssertTrue(ProvisioningPhase.validatingISO.isActive)
        XCTAssertTrue(ProvisioningPhase.creatingDisk.isActive)
        XCTAssertTrue(ProvisioningPhase.installingWindows.isActive)
        XCTAssertTrue(ProvisioningPhase.postInstallProvisioning.isActive)
        XCTAssertTrue(ProvisioningPhase.creatingSnapshot.isActive)

        XCTAssertFalse(ProvisioningPhase.complete.isActive)
        XCTAssertFalse(ProvisioningPhase.failed.isActive)
        XCTAssertFalse(ProvisioningPhase.cancelled.isActive)
    }

    func testProvisioningPhase_ProgressWeights() {
        // All active phase weights should sum to ~1.0
        let activePhases: [ProvisioningPhase] = [
            .validatingISO,
            .creatingDisk,
            .installingWindows,
            .postInstallProvisioning,
            .creatingSnapshot,
        ]

        let totalWeight = activePhases.reduce(0.0) { $0 + $1.progressWeight }
        XCTAssertEqual(totalWeight, 1.0, accuracy: 0.01)

        // Terminal phases should have zero weight
        XCTAssertEqual(ProvisioningPhase.idle.progressWeight, 0.0)
        XCTAssertEqual(ProvisioningPhase.complete.progressWeight, 0.0)
        XCTAssertEqual(ProvisioningPhase.failed.progressWeight, 0.0)
        XCTAssertEqual(ProvisioningPhase.cancelled.progressWeight, 0.0)
    }

    // MARK: - ProvisioningState Tests

    func testProvisioningState_IdleState() {
        let state = ProvisioningState.idle

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.phaseProgress, 0.0)
        XCTAssertEqual(state.overallProgress, 0.0)
        XCTAssertNil(state.error)
    }

    func testProvisioningState_ProgressClamping() {
        let overState = ProvisioningState(phase: .installingWindows, phaseProgress: 1.5)
        XCTAssertEqual(overState.phaseProgress, 1.0)

        let underState = ProvisioningState(phase: .installingWindows, phaseProgress: -0.5)
        XCTAssertEqual(underState.phaseProgress, 0.0)
    }

    func testProvisioningState_OverallProgressCalculation() {
        // At start of validatingISO
        let isoStart = ProvisioningState(phase: .validatingISO, phaseProgress: 0.0)
        XCTAssertEqual(isoStart.overallProgress, 0.0, accuracy: 0.01)

        // Halfway through validatingISO
        let isoMid = ProvisioningState(phase: .validatingISO, phaseProgress: 0.5)
        XCTAssertEqual(isoMid.overallProgress, 0.01, accuracy: 0.01)  // 0.02 * 0.5

        // At start of installingWindows (after ISO validation + disk creation)
        let windowsStart = ProvisioningState(phase: .installingWindows, phaseProgress: 0.0)
        let expectedWindowsStart = 0.02 + 0.03  // ISO + disk weights
        XCTAssertEqual(windowsStart.overallProgress, expectedWindowsStart, accuracy: 0.01)

        // Complete state should be 1.0
        let complete = ProvisioningState(phase: .complete)
        XCTAssertEqual(complete.overallProgress, 1.0, accuracy: 0.01)
    }

    func testProvisioningState_DefaultMessage() {
        let state = ProvisioningState(phase: .validatingISO)
        XCTAssertEqual(state.message, "Validating Windows ISO")

        let customState = ProvisioningState(phase: .validatingISO, message: "Custom message")
        XCTAssertEqual(customState.message, "Custom message")
    }

    // MARK: - State Transition Tests

    func testStateTransition_ValidTransitions() {
        XCTAssertTrue(ProvisioningStateTransition.isValid(from: .idle, to: .validatingISO))
        XCTAssertTrue(ProvisioningStateTransition.isValid(from: .validatingISO, to: .creatingDisk))
        XCTAssertTrue(ProvisioningStateTransition.isValid(from: .creatingDisk, to: .installingWindows))
        XCTAssertTrue(ProvisioningStateTransition.isValid(from: .installingWindows, to: .postInstallProvisioning))
        XCTAssertTrue(ProvisioningStateTransition.isValid(from: .postInstallProvisioning, to: .creatingSnapshot))
        XCTAssertTrue(ProvisioningStateTransition.isValid(from: .creatingSnapshot, to: .complete))
    }

    func testStateTransition_CancellationFromAnyActivePhase() {
        let activePhases: [ProvisioningPhase] = [
            .idle,
            .validatingISO,
            .creatingDisk,
            .installingWindows,
            .postInstallProvisioning,
            .creatingSnapshot,
        ]

        for phase in activePhases {
            XCTAssertTrue(
                ProvisioningStateTransition.isValid(from: phase, to: .cancelled),
                "Should be able to cancel from \(phase)"
            )
        }
    }

    func testStateTransition_FailureFromActivePhases() {
        let activePhases: [ProvisioningPhase] = [
            .validatingISO,
            .creatingDisk,
            .installingWindows,
            .postInstallProvisioning,
            .creatingSnapshot,
        ]

        for phase in activePhases {
            XCTAssertTrue(
                ProvisioningStateTransition.isValid(from: phase, to: .failed),
                "Should be able to fail from \(phase)"
            )
        }
    }

    func testStateTransition_InvalidTransitions() {
        // Can't go backwards
        XCTAssertFalse(ProvisioningStateTransition.isValid(from: .creatingDisk, to: .validatingISO))

        // Can't skip phases
        XCTAssertFalse(ProvisioningStateTransition.isValid(from: .idle, to: .installingWindows))

        // Can't transition from terminal states (except to idle for retry)
        XCTAssertFalse(ProvisioningStateTransition.isValid(from: .complete, to: .validatingISO))
        XCTAssertFalse(ProvisioningStateTransition.isValid(from: .complete, to: .failed))
    }

    func testStateTransition_RetryFromTerminalStates() {
        XCTAssertTrue(ProvisioningStateTransition.isValid(from: .failed, to: .idle))
        XCTAssertTrue(ProvisioningStateTransition.isValid(from: .cancelled, to: .idle))
    }

    func testStateTransition_TransitionSuccess() {
        let initialState = ProvisioningState.idle

        let result = ProvisioningStateTransition.transition(
            from: initialState,
            to: .validatingISO,
            message: "Starting validation"
        )

        switch result {
        case .success(let newState):
            XCTAssertEqual(newState.phase, .validatingISO)
            XCTAssertEqual(newState.message, "Starting validation")
            XCTAssertEqual(newState.phaseProgress, 0.0)
        case .failure(let error):
            XCTFail("Transition should succeed: \(error)")
        }
    }

    func testStateTransition_TransitionFailure() {
        let state = ProvisioningState(phase: .idle)

        let result = ProvisioningStateTransition.transition(
            from: state,
            to: .installingWindows,
            message: "Skipping phases"
        )

        switch result {
        case .success:
            XCTFail("Transition should fail - can't skip phases")
        case .failure(let error):
            // Error should indicate invalid state transition
            XCTAssertNotNil(error.failureReason)
            XCTAssertTrue(
                error.failureReason?.contains("idle") == true ||
                    error.failureReason?.contains("installingWindows") == true ||
                    error.failureReason?.contains("installing_windows") == true,
                "Error should mention the invalid states"
            )
        }
    }

    func testStateTransition_ValidNextPhases() {
        let idleNext = ProvisioningStateTransition.validNextPhases(from: .idle)
        XCTAssertTrue(idleNext.contains(.validatingISO))
        XCTAssertTrue(idleNext.contains(.cancelled))
        XCTAssertEqual(idleNext.count, 2)

        let completeNext = ProvisioningStateTransition.validNextPhases(from: .complete)
        XCTAssertTrue(completeNext.isEmpty)
    }

    // MARK: - ProvisioningContext Tests

    func testProvisioningContext_Initialization() {
        let isoPath = URL(fileURLWithPath: "/path/to/windows.iso")
        let diskPath = URL(fileURLWithPath: "/path/to/disk.img")

        let context = ProvisioningContext(isoPath: isoPath, diskImagePath: diskPath)

        XCTAssertEqual(context.isoPath, isoPath)
        XCTAssertEqual(context.diskImagePath, diskPath)
        XCTAssertNil(context.isoValidation)
        XCTAssertNil(context.diskCreationResult)
        XCTAssertNil(context.windowsVersion)
        XCTAssertNil(context.agentVersion)
        XCTAssertNil(context.diskUsageBytes)
    }

    func testProvisioningContext_Elapsed() {
        let isoPath = URL(fileURLWithPath: "/path/to/windows.iso")
        let diskPath = URL(fileURLWithPath: "/path/to/disk.img")
        let startTime = Date().addingTimeInterval(-10)  // 10 seconds ago

        let context = ProvisioningContext(isoPath: isoPath, diskImagePath: diskPath, startedAt: startTime)

        XCTAssertGreaterThanOrEqual(context.elapsed, 10.0)
        XCTAssertLessThan(context.elapsed, 11.0)
    }

    // MARK: - ProvisioningProgress Tests

    func testProvisioningProgress_FromState() {
        let state = ProvisioningState(
            phase: .installingWindows,
            phaseProgress: 0.5,
            message: "Installing..."
        )

        let progress = ProvisioningProgress(from: state, estimatedSecondsRemaining: 300)

        XCTAssertEqual(progress.phase, .installingWindows)
        XCTAssertEqual(progress.phaseProgress, 0.5)
        XCTAssertEqual(progress.message, "Installing...")
        XCTAssertEqual(progress.estimatedSecondsRemaining, 300)
    }

    // MARK: - ProvisioningResult Tests

    func testProvisioningResult_Success() {
        let isoPath = URL(fileURLWithPath: "/path/to/windows.iso")
        let diskPath = URL(fileURLWithPath: "/path/to/disk.img")
        var context = ProvisioningContext(isoPath: isoPath, diskImagePath: diskPath)
        context.windowsVersion = "Windows 11 23H2"
        context.agentVersion = "1.0.0"
        context.diskUsageBytes = 10_000_000_000

        let result = ProvisioningResult.success(from: context)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.finalPhase, .complete)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.windowsVersion, "Windows 11 23H2")
        XCTAssertEqual(result.agentVersion, "1.0.0")
        XCTAssertEqual(result.diskUsageBytes, 10_000_000_000)
    }

    func testProvisioningResult_Failure() {
        let isoPath = URL(fileURLWithPath: "/path/to/windows.iso")
        let diskPath = URL(fileURLWithPath: "/path/to/disk.img")
        let context = ProvisioningContext(isoPath: isoPath, diskImagePath: diskPath)
        let error = WinRunError.isoInvalid(reason: "Not ARM64")

        let result = ProvisioningResult.failure(
            phase: .validatingISO,
            error: error,
            context: context
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.finalPhase, .validatingISO)
        XCTAssertNotNil(result.error)
    }

    func testProvisioningResult_Cancelled() {
        let isoPath = URL(fileURLWithPath: "/path/to/windows.iso")
        let diskPath = URL(fileURLWithPath: "/path/to/disk.img")
        let context = ProvisioningContext(isoPath: isoPath, diskImagePath: diskPath)

        let result = ProvisioningResult.cancelled(context: context)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.finalPhase, .cancelled)
        XCTAssertEqual(result.error, .cancelled)
    }

    // MARK: - RollbackResult Tests

    func testRollbackResult_Success() {
        let result = RollbackResult(success: true, freedBytes: 50_000_000_000, error: nil)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.freedBytes, 50_000_000_000)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.description.contains("47683"))  // ~47GB in MB
    }

    func testRollbackResult_SuccessNoDisk() {
        let result = RollbackResult(success: true, freedBytes: 0, error: nil)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.description.contains("No disk image"))
    }

    func testRollbackResult_Failure() {
        let error = WinRunError.internalError(message: "Permission denied")
        let result = RollbackResult(success: false, freedBytes: 0, error: error)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.description.contains("failed"))
    }
}
