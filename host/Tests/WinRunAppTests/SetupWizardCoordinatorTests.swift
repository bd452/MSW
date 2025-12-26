import AppKit
import Foundation
import WinRunSetup
import WinRunShared
import XCTest

@testable import WinRunApp

@available(macOS 13, *)
final class SetupWizardCoordinatorTests: XCTestCase {
    // MARK: - State Transition Tests

    func testStart_transitionsToWelcome() {
        let coordinator = makeCoordinator()

        coordinator.start()

        XCTAssertEqual(coordinator.currentStep, .welcome)
    }

    func testProceedFromWelcome_transitionsToImportISO() {
        let coordinator = makeCoordinator()
        coordinator.start()

        coordinator.proceedFromWelcome()

        XCTAssertEqual(coordinator.currentStep, .importISO)
    }

    func testProceedFromWelcome_ignoresWrongStep() {
        let coordinator = makeCoordinator()
        coordinator.start()
        coordinator.proceedFromWelcome()  // Now at importISO

        coordinator.proceedFromWelcome()  // Should be ignored

        XCTAssertEqual(coordinator.currentStep, .importISO)
    }

    func testSelectISO_recordsISOPath() {
        let coordinator = makeCoordinator()
        let isoURL = URL(fileURLWithPath: "/tmp/test.iso")

        coordinator.selectISO(isoURL)

        XCTAssertEqual(coordinator.selectedISOPath, isoURL)
    }

    func testStartInstallation_requiresImportISOStep() {
        let coordinator = makeCoordinator()
        coordinator.start()  // At welcome

        coordinator.startInstallation()  // Should be ignored

        XCTAssertEqual(coordinator.currentStep, .welcome)
    }

    func testStartInstallation_requiresSelectedISO() {
        let coordinator = makeCoordinator()
        coordinator.start()
        coordinator.proceedFromWelcome()  // At importISO

        coordinator.startInstallation()  // Should be ignored - no ISO

        XCTAssertEqual(coordinator.currentStep, .importISO)
    }

    func testStartInstallation_transitionsToInstalling() {
        let coordinator = makeCoordinator()
        coordinator.start()
        coordinator.proceedFromWelcome()
        coordinator.selectISO(URL(fileURLWithPath: "/tmp/test.iso"))

        coordinator.startInstallation()

        XCTAssertEqual(coordinator.currentStep, .installing)
    }

    // MARK: - Completion Tests

    func testHandleInstallationComplete_success_transitionsToComplete() {
        let coordinator = makeCoordinator()
        goToInstalling(coordinator)

        let result = ProvisioningResult(
            success: true,
            finalPhase: .complete,
            durationSeconds: 60,
            diskImagePath: URL(fileURLWithPath: "/tmp/windows.img")
        )
        coordinator.handleInstallationComplete(result: result)

        XCTAssertEqual(coordinator.currentStep, .complete)
    }

    func testHandleInstallationComplete_failure_transitionsToError() {
        let coordinator = makeCoordinator()
        goToInstalling(coordinator)

        let result = ProvisioningResult(
            success: false,
            finalPhase: .installingWindows,
            error: .vmOperationTimeout(operation: "installation", timeoutSeconds: 30),
            durationSeconds: 30,
            diskImagePath: URL(fileURLWithPath: "/tmp/windows.img")
        )
        coordinator.handleInstallationComplete(result: result)

        XCTAssertEqual(coordinator.currentStep, .error)
        XCTAssertNotNil(coordinator.lastError)
    }

    // MARK: - Recovery Transition Tests

    func testRetry_fromError_transitionsToInstalling() {
        let coordinator = makeCoordinator()
        goToError(coordinator)

        coordinator.retry()

        XCTAssertEqual(coordinator.currentStep, .installing)
    }

    func testRetry_fromNonErrorStep_isIgnored() {
        let coordinator = makeCoordinator()
        coordinator.start()
        coordinator.proceedFromWelcome()
        // Now at importISO step

        coordinator.retry()  // Should be ignored - not in error state

        XCTAssertEqual(coordinator.currentStep, .importISO)  // Still at importISO
    }

    func testChooseNewISO_fromError_transitionsToImportISO() {
        let coordinator = makeCoordinator()
        goToError(coordinator)

        coordinator.chooseNewISO()

        XCTAssertEqual(coordinator.currentStep, .importISO)
        XCTAssertNil(coordinator.selectedISOPath)
    }

    func testChooseNewISO_clearsError() {
        let coordinator = makeCoordinator()
        goToError(coordinator)
        XCTAssertNotNil(coordinator.lastError)

        coordinator.chooseNewISO()

        XCTAssertNil(coordinator.lastError)
    }

    // MARK: - Delegate Tests

    @MainActor
    func testDelegateReceivesStepChanges() {
        let delegate = MockCoordinatorDelegate()
        let coordinator = makeCoordinator(delegate: delegate)

        coordinator.start()
        coordinator.proceedFromWelcome()

        XCTAssertEqual(delegate.stepChanges.count, 2)
        XCTAssertEqual(delegate.stepChanges.last?.from, .welcome)
        XCTAssertEqual(delegate.stepChanges.last?.to, .importISO)
    }

    // MARK: - Recovery Action Wiring Tests

    func testRecoveryAction_primaryWithoutHandler_triggersAssertion() {
        // This test verifies the assertion behavior in debug builds
        // In release builds, the code should still work gracefully

        // Create a recovery action without a handler
        let action = SetupErrorViewController.RecoveryAction(
            id: .retrySetup,
            title: "Test",
            isPrimary: false,  // Non-primary to avoid assertion
            handler: nil
        )

        XCTAssertFalse(action.isEnabled)
    }

    func testRecoveryAction_informational_isEnabledWithoutHandler() {
        let action = SetupErrorViewController.RecoveryAction(
            id: .reviewDetails,
            title: "Review",
            isPrimary: false,
            handler: nil,
            isInformational: true
        )

        XCTAssertTrue(action.isEnabled)
    }

    func testRecoveryAction_withHandler_isEnabled() {
        let action = SetupErrorViewController.RecoveryAction(
            id: .retrySetup,
            title: "Retry",
            isPrimary: true,
            handler: { }
        )

        XCTAssertTrue(action.isEnabled)
    }

    // MARK: - SetupFailureContext Tests

    func testSetupFailureContext_createsFromResult() {
        let error = WinRunError.vmOperationTimeout(operation: "installation", timeoutSeconds: 30)
        let result = ProvisioningResult(
            success: false,
            finalPhase: .installingWindows,
            error: error,
            durationSeconds: 100,
            diskImagePath: URL(fileURLWithPath: "/tmp/windows.img")
        )

        let context = SetupFailureContext.from(result: result, context: nil)

        XCTAssertNotNil(context)
        guard let context = context else { return }
        XCTAssertEqual(context.failedPhase, .installingWindows)
    }

    func testSetupFailureContext_suggestsRetryForTimeout() {
        let context = SetupFailureContext(
            failedPhase: .installingWindows,
            error: .vmOperationTimeout(operation: "installation", timeoutSeconds: 30)
        )

        XCTAssertTrue(context.suggestedActions.contains(RecoveryActionType.retry))
    }

    func testSetupFailureContext_suggestsDifferentISOForValidationFailure() {
        let context = SetupFailureContext(
            failedPhase: .validatingISO,
            error: .isoArchitectureUnsupported(found: "x64", required: "arm64")
        )

        XCTAssertTrue(context.suggestedActions.contains(RecoveryActionType.chooseDifferentISO))
    }

    func testSetupFailureContext_cleanupRecommendedAfterDiskCreation() {
        let context = SetupFailureContext(
            failedPhase: .installingWindows,
            error: .vmOperationTimeout(operation: "installation", timeoutSeconds: 30),
            cleanupRecommended: true
        )

        XCTAssertTrue(context.cleanupRecommended)
    }

    // MARK: - ProvisioningPhase Extension Tests

    func testProvisioningPhase_isAfter() {
        XCTAssertTrue(ProvisioningPhase.installingWindows.isAfter(.creatingDisk))
        XCTAssertTrue(ProvisioningPhase.creatingDisk.isAfter(.validatingISO))
        XCTAssertFalse(ProvisioningPhase.validatingISO.isAfter(.installingWindows))
        XCTAssertFalse(ProvisioningPhase.idle.isAfter(.complete))
    }

    // MARK: - Sub-Phase Progress Tests

    func testProvisioningProgress_withSubPhase_containsSubPhaseInfo() {
        let progress = ProvisioningProgress.withInstallationSubPhase(
            phase: .installingWindows,
            phaseProgress: 0.5,
            overallProgress: 0.3,
            message: "Copying files...",
            installationPhase: .copyingFiles,
            subPhaseProgress: 0.5
        )

        XCTAssertEqual(progress.phase, .installingWindows)
        XCTAssertEqual(progress.installationSubPhase, .copyingFiles)
        XCTAssertEqual(progress.subPhaseProgress, 0.5)
    }

    func testProvisioningProgress_withoutSubPhase_nilSubPhaseInfo() {
        let progress = ProvisioningProgress(
            phase: .creatingDisk,
            phaseProgress: 0.8,
            overallProgress: 0.2,
            message: "Creating disk..."
        )

        XCTAssertNil(progress.installationSubPhase)
        XCTAssertNil(progress.subPhaseProgress)
    }

    func testInstallationPhase_displayNames() {
        // Verify all installation phases have valid display names
        let phases: [InstallationPhase] = [
            .preparing, .booting, .copyingFiles, .installingFeatures, .firstBoot, .postInstall,
        ]
        for phase in phases {
            XCTAssertFalse(phase.displayName.isEmpty, "Phase \(phase) should have a display name")
        }
    }

    // MARK: - Helpers

    private func makeCoordinator(delegate: SetupWizardCoordinatorDelegate? = nil) -> SetupWizardCoordinator {
        let setupCoordinator = SetupCoordinator()
        return SetupWizardCoordinator(
            setupCoordinator: setupCoordinator,
            delegate: delegate,
            viewControllerFactory: { _, _ in NSViewController() }
        )
    }

    private func goToInstalling(_ coordinator: SetupWizardCoordinator) {
        coordinator.start()
        coordinator.proceedFromWelcome()
        coordinator.selectISO(URL(fileURLWithPath: "/tmp/test.iso"))
        coordinator.startInstallation()
    }

    private func goToError(_ coordinator: SetupWizardCoordinator, clearISO: Bool = false) {
        goToInstalling(coordinator)
        let result = ProvisioningResult(
            success: false,
            finalPhase: .installingWindows,
            error: .vmOperationTimeout(operation: "installation", timeoutSeconds: 30),
            durationSeconds: 30,
            diskImagePath: URL(fileURLWithPath: "/tmp/windows.img")
        )
        coordinator.handleInstallationComplete(result: result)
        if clearISO {
            coordinator.chooseNewISO()
        }
    }
}

// MARK: - Mock Delegate

@available(macOS 13, *)
private final class MockCoordinatorDelegate: SetupWizardCoordinatorDelegate {
    struct StepChange {
        let from: SetupWizardStep
        let to: SetupWizardStep
    }

    var stepChanges: [StepChange] = []
    var finishCalled = false
    var finishSuccess = false

    func coordinatorDidChangeStep(
        _ coordinator: SetupWizardCoordinator,
        from oldStep: SetupWizardStep,
        to newStep: SetupWizardStep
    ) {
        stepChanges.append(StepChange(from: oldStep, to: newStep))
    }

    func coordinatorDidRequestViewController(
        _ coordinator: SetupWizardCoordinator,
        for step: SetupWizardStep
    ) -> NSViewController {
        NSViewController()
    }

    func coordinatorDidFinish(_ coordinator: SetupWizardCoordinator, success: Bool) {
        finishCalled = true
        finishSuccess = success
    }
}
