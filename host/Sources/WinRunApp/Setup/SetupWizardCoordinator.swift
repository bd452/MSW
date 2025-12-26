import AppKit
import Foundation
import WinRunSetup
import WinRunShared

// MARK: - Wizard Step

/// Represents the current step in the setup wizard.
@available(macOS 13, *)
public enum SetupWizardStep: String, Sendable, Equatable {
    case welcome
    case importISO
    case installing
    case complete
    case error
}

// MARK: - Coordinator Protocol

/// Protocol for the wizard coordinator, enabling testability.
@available(macOS 13, *)
public protocol SetupWizardCoordinatorProtocol: AnyObject {
    var currentStep: SetupWizardStep { get }
    var selectedISOPath: URL? { get }

    func start()
    func proceedFromWelcome()
    func selectISO(_ isoPath: URL)
    func startInstallation()
    func cancel()
    func handleInstallationComplete(result: ProvisioningResult)
    func retry()
    func chooseNewISO()
    func finish()
}

// MARK: - Coordinator Delegate

/// Delegate for receiving wizard coordinator events.
@available(macOS 13, *)
public protocol SetupWizardCoordinatorDelegate: AnyObject {
    func coordinatorDidChangeStep(_ coordinator: SetupWizardCoordinator, from oldStep: SetupWizardStep, to newStep: SetupWizardStep)
    func coordinatorDidRequestViewController(_ coordinator: SetupWizardCoordinator, for step: SetupWizardStep) -> NSViewController
    func coordinatorDidFinish(_ coordinator: SetupWizardCoordinator, success: Bool)
}

// MARK: - Setup Wizard Coordinator

/// Orchestrates the setup wizard flow from welcome to complete/error.
///
/// This coordinator manages the state machine for the first-run experience:
/// 1. Welcome screen → User learns about requirements
/// 2. ISO Import → User selects a Windows ARM64 ISO
/// 3. Installation → Progress display while Windows is installed
/// 4. Complete/Error → Success message or actionable error recovery
@available(macOS 13, *)
public final class SetupWizardCoordinator: SetupWizardCoordinatorProtocol {
    // MARK: - Types

    public typealias ViewControllerFactory = (SetupWizardStep, SetupWizardCoordinator) -> NSViewController

    // MARK: - Properties

    public private(set) var currentStep: SetupWizardStep = .welcome
    public private(set) var selectedISOPath: URL?
    public private(set) var lastError: Error?
    public private(set) var lastResult: ProvisioningResult?

    private weak var delegate: SetupWizardCoordinatorDelegate?
    private let setupCoordinator: SetupCoordinator
    private let viewControllerFactory: ViewControllerFactory
    private let logger: Logger

    private var window: NSWindow?
    private var provisioningTask: Task<Void, Never>?

    // MARK: - Configuration

    private var diskImagePath: URL {
        DiskImageConfiguration.defaultPath
    }

    // MARK: - Initialization

    public init(
        setupCoordinator: SetupCoordinator,
        delegate: SetupWizardCoordinatorDelegate? = nil,
        viewControllerFactory: ViewControllerFactory? = nil,
        logger: Logger = StandardLogger(subsystem: "WinRunApp.SetupWizardCoordinator")
    ) {
        self.setupCoordinator = setupCoordinator
        self.delegate = delegate
        self.viewControllerFactory = viewControllerFactory ?? Self.defaultViewControllerFactory
        self.logger = logger
    }

    // MARK: - Public API

    /// Starts the wizard by presenting the welcome screen.
    public func start() {
        transitionTo(.welcome)
    }

    /// Proceeds from the welcome screen to ISO import.
    public func proceedFromWelcome() {
        guard currentStep == .welcome else {
            logger.warning("proceedFromWelcome called from invalid step: \(currentStep.rawValue)")
            return
        }
        transitionTo(.importISO)
    }

    /// Records the selected ISO path.
    public func selectISO(_ isoPath: URL) {
        selectedISOPath = isoPath
        logger.info("ISO selected: \(isoPath.lastPathComponent)")
    }

    /// Starts the Windows installation process.
    public func startInstallation() {
        guard currentStep == .importISO else {
            logger.warning("startInstallation called from invalid step: \(currentStep.rawValue)")
            return
        }
        guard let isoPath = selectedISOPath else {
            logger.error("startInstallation called without selected ISO")
            return
        }

        transitionTo(.installing)
        beginProvisioning(isoPath: isoPath)
    }

    /// Cancels the current installation.
    public func cancel() {
        provisioningTask?.cancel()
        Task {
            await setupCoordinator.cancel()
        }
        logger.info("Installation cancelled by user")
    }

    /// Handles completion of the installation process.
    public func handleInstallationComplete(result: ProvisioningResult) {
        lastResult = result

        if result.success {
            transitionTo(.complete)
        } else {
            lastError = result.error
            transitionTo(.error)
        }
    }

    /// Retries the installation after a failure.
    public func retry() {
        guard currentStep == .error else {
            logger.warning("retry called from invalid step: \(currentStep.rawValue)")
            return
        }
        guard let isoPath = selectedISOPath else {
            // No ISO selected - go back to import
            transitionTo(.importISO)
            return
        }

        lastError = nil
        transitionTo(.installing)
        beginProvisioning(isoPath: isoPath)
    }

    /// Returns to ISO selection to choose a different ISO.
    public func chooseNewISO() {
        guard currentStep == .error || currentStep == .importISO else {
            logger.warning("chooseNewISO called from invalid step: \(currentStep.rawValue)")
            return
        }
        selectedISOPath = nil
        lastError = nil
        transitionTo(.importISO)
    }

    /// Performs rollback cleanup and then returns to ISO selection.
    public func rollbackAndChooseNewISO() {
        guard currentStep == .error else {
            logger.warning("rollbackAndChooseNewISO called from invalid step: \(currentStep.rawValue)")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            _ = await self.setupCoordinator.rollback()
            await MainActor.run { [weak self] in
                self?.chooseNewISO()
            }
        }
    }

    /// Finishes the wizard (after success or user gives up).
    public func finish() {
        delegate?.coordinatorDidFinish(self, success: currentStep == .complete)
    }

    // MARK: - Window Management

    /// Sets the window being managed by this coordinator.
    public func setWindow(_ window: NSWindow) {
        self.window = window
    }

    /// Updates the window's content to show the view controller for the given step.
    public func updateWindowContent(for step: SetupWizardStep) {
        let viewController: NSViewController
        if let delegate = delegate {
            viewController = delegate.coordinatorDidRequestViewController(self, for: step)
        } else {
            viewController = viewControllerFactory(step, self)
        }
        window?.contentViewController = viewController
    }

    // MARK: - Private: State Transitions

    private func transitionTo(_ newStep: SetupWizardStep) {
        let oldStep = currentStep
        guard isValidTransition(from: oldStep, to: newStep) else {
            logger.warning("Invalid transition from \(oldStep.rawValue) to \(newStep.rawValue)")
            return
        }

        currentStep = newStep
        logger.info("Wizard transition: \(oldStep.rawValue) → \(newStep.rawValue)")

        delegate?.coordinatorDidChangeStep(self, from: oldStep, to: newStep)
        updateWindowContent(for: newStep)
    }

    private func isValidTransition(from: SetupWizardStep, to: SetupWizardStep) -> Bool {
        switch (from, to) {
        case (.welcome, .welcome): return true  // Initial start
        case (.welcome, .importISO): return true
        case (.importISO, .installing): return true
        case (.importISO, .importISO): return true  // Re-select ISO
        case (.installing, .complete): return true
        case (.installing, .error): return true
        case (.error, .importISO): return true
        case (.error, .installing): return true  // Retry
        case (.complete, _): return false  // Terminal
        default: return false
        }
    }

    // MARK: - Private: Provisioning

    private func beginProvisioning(isoPath: URL) {
        provisioningTask = Task { [weak self] in
            guard let self else { return }

            let config = SetupCoordinatorConfiguration(
                isoPath: isoPath,
                diskImagePath: self.diskImagePath
            )

            let result = await self.setupCoordinator.startProvisioning(with: config)

            await MainActor.run { [weak self] in
                self?.handleInstallationComplete(result: result)
            }
        }
    }

    // MARK: - Default View Controller Factory

    private static func defaultViewControllerFactory(
        step: SetupWizardStep,
        coordinator: SetupWizardCoordinator
    ) -> NSViewController {
        switch step {
        case .welcome:
            return createWelcomeViewController(coordinator: coordinator)

        case .importISO:
            return createISOImportViewController(coordinator: coordinator)

        case .installing:
            return createProgressViewController(coordinator: coordinator)

        case .complete:
            return createCompleteViewController(coordinator: coordinator)

        case .error:
            return createErrorViewController(coordinator: coordinator)
        }
    }

    private static func createWelcomeViewController(
        coordinator: SetupWizardCoordinator
    ) -> NSViewController {
        let vc = WelcomeViewController()
        vc.onContinue = { [weak coordinator] in
            coordinator?.proceedFromWelcome()
        }
        return vc
    }

    private static func createISOImportViewController(
        coordinator: SetupWizardCoordinator
    ) -> NSViewController {
        let vc = ISOImportViewController()
        vc.onISOSelected = { [weak coordinator] url in
            coordinator?.selectISO(url)
        }
        vc.onContinue = { [weak coordinator] in
            coordinator?.startInstallation()
        }
        return vc
    }

    private static func createProgressViewController(
        coordinator: SetupWizardCoordinator
    ) -> NSViewController {
        let vc = InstallProgressViewController()
        vc.onCancelRequested = { [weak coordinator] in
            coordinator?.cancel()
        }
        vc.start()
        return vc
    }

    private static func createCompleteViewController(
        coordinator: SetupWizardCoordinator
    ) -> NSViewController {
        let result = coordinator.lastResult ?? ProvisioningResult(
            success: true,
            finalPhase: .complete,
            durationSeconds: 0,
            diskImagePath: coordinator.diskImagePath
        )
        let vc = SetupCompleteViewController(result: result)
        vc.onDone = { [weak coordinator] in
            coordinator?.finish()
        }
        return vc
    }

    private static func createErrorViewController(
        coordinator: SetupWizardCoordinator
    ) -> NSViewController {
        // Try to create rich failure context from the last result
        if let result = coordinator.lastResult,
           let context = createFailureContext(from: result, coordinator: coordinator) {
            return SetupErrorViewController(
                failureContext: context,
                onRetrySetup: { [weak coordinator] in
                    coordinator?.retry()
                },
                onChooseDifferentISO: { [weak coordinator] in
                    coordinator?.chooseNewISO()
                },
                onRollback: { [weak coordinator] in
                    coordinator?.rollbackAndChooseNewISO()
                },
                onContactSupport: nil  // Uses default behavior
            )
        }

        // Fallback to basic error display
        let error = coordinator.lastError ?? WinRunError.internalError(message: "Unknown error")
        return SetupErrorViewController(
            error: error,
            onRetrySetup: { [weak coordinator] in
                coordinator?.retry()
            },
            onChooseDifferentISO: { [weak coordinator] in
                coordinator?.chooseNewISO()
            },
            onContactSupport: nil
        )
    }

    private static func createFailureContext(
        from result: ProvisioningResult,
        coordinator: SetupWizardCoordinator
    ) -> SetupFailureContext? {
        guard !result.success, let error = result.error else { return nil }

        let freeDiskSpace: UInt64? = {
            let url = coordinator.diskImagePath.deletingLastPathComponent()
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage.map { UInt64($0) }
        }()

        return SetupFailureContext(
            failedPhase: result.finalPhase,
            error: error,
            isoPath: coordinator.selectedISOPath,
            diskImagePath: result.diskImagePath,
            diskUsageBytes: result.diskUsageBytes,
            freeDiskSpaceBytes: freeDiskSpace,
            cleanupRecommended: result.finalPhase.isAfter(.creatingDisk)
        )
    }
}

// MARK: - ProvisioningDelegate Conformance

@available(macOS 13, *)
extension SetupWizardCoordinator: ProvisioningDelegate {
    public func provisioningDidUpdateProgress(_ progress: ProvisioningProgress) {
        Task { @MainActor [weak self] in
            guard let self, self.currentStep == .installing else { return }
            if let progressVC = self.window?.contentViewController as? InstallProgressViewController {
                progressVC.apply(progress: progress)
            }
        }
    }

    public func provisioningDidChangePhase(from oldPhase: ProvisioningPhase, to newPhase: ProvisioningPhase) {
        logger.debug("Provisioning phase: \(oldPhase.rawValue) → \(newPhase.rawValue)")
    }

    public func provisioningDidComplete(with result: ProvisioningResult) {
        Task { @MainActor [weak self] in
            self?.handleInstallationComplete(result: result)
        }
    }
}
