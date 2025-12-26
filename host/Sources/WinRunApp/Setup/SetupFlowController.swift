import AppKit
import Foundation
import WinRunSetup
import WinRunShared

/// Routes WinRun.app startup into either the setup wizard or normal operation.
///
/// When setup is needed, this controller creates a SetupWizardCoordinator to manage
/// the full setup flow from welcome through to completion or error recovery.
@available(macOS 13, *)
final class SetupFlowController {
    typealias SetupWindowPresenter = (_ controller: NSViewController) -> NSWindow
    typealias NormalOperationBlock = () -> Void

    private let logger: Logger
    private let preflight: ProvisioningPreflightResult
    private let presentSetupWindow: SetupWindowPresenter
    private let setupCoordinatorFactory: () -> SetupCoordinator

    private var window: NSWindow?
    private var wizardCoordinator: SetupWizardCoordinator?
    private var normalOperationBlock: NormalOperationBlock?

    init(
        preflight: ProvisioningPreflightResult,
        logger: Logger = StandardLogger(subsystem: "WinRunApp.SetupFlowController"),
        presentSetupWindow: @escaping SetupWindowPresenter = SetupFlowController.defaultSetupWindowPresenter,
        setupCoordinatorFactory: @escaping () -> SetupCoordinator = { SetupCoordinator() }
    ) {
        self.preflight = preflight
        self.logger = logger
        self.presentSetupWindow = presentSetupWindow
        self.setupCoordinatorFactory = setupCoordinatorFactory
    }

    func routeToSetupOrNormalOperation(normalOperation: @escaping NormalOperationBlock) {
        switch preflight {
        case .ready:
            normalOperation()

        case .needsSetup(let diskImagePath, let reason):
            logger.info("Routing to setup UI. diskImagePath=\(diskImagePath.path) reason=\(reason.rawValue)")
            normalOperationBlock = normalOperation
            presentSetupWizard(diskImagePath: diskImagePath, reason: reason)
        }
    }

    private func presentSetupWizard(diskImagePath: URL, reason: ProvisioningPreflightResult.Reason) {
        let setupCoordinator = setupCoordinatorFactory()
        let wizard = SetupWizardCoordinator(
            setupCoordinator: setupCoordinator,
            delegate: self,
            logger: logger
        )

        // Configure the SetupCoordinator to report progress to the wizard
        Task {
            await setupCoordinator.setDelegate(wizard)
        }

        wizardCoordinator = wizard

        // Present the initial view
        let initialController = wizard.createViewController(for: .welcome)
        let window = presentSetupWindow(initialController)
        window.title = "WinRun Setup"
        self.window = window

        wizard.setWindow(window)
        wizard.start()
    }

    /// Presents a legacy placeholder for edge cases (e.g., disk path is a directory).
    private func presentSetupPlaceholder(diskImagePath: URL, reason: ProvisioningPreflightResult.Reason) {
        let controller = SetupPlaceholderViewController(
            diskImagePath: diskImagePath,
            reason: reason
        )
        self.window = presentSetupWindow(controller)
    }

    private static func defaultSetupWindowPresenter(controller: NSViewController) -> NSWindow {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WinRun Setup"
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

// MARK: - SetupWizardCoordinatorDelegate

@available(macOS 13, *)
extension SetupFlowController: SetupWizardCoordinatorDelegate {
    func coordinatorDidChangeStep(
        _ coordinator: SetupWizardCoordinator,
        from oldStep: SetupWizardStep,
        to newStep: SetupWizardStep
    ) {
        logger.debug("Setup wizard step: \(oldStep.rawValue) → \(newStep.rawValue)")
    }

    func coordinatorDidRequestViewController(
        _ coordinator: SetupWizardCoordinator,
        for step: SetupWizardStep
    ) -> NSViewController {
        // Use the coordinator's view controller factory
        return coordinator.createViewController(for: step)
    }

    func coordinatorDidFinish(_ coordinator: SetupWizardCoordinator, success: Bool) {
        logger.info("Setup wizard finished. success=\(success)")

        if success {
            // Close setup window and proceed to normal operation
            window?.close()
            window = nil
            wizardCoordinator = nil
            normalOperationBlock?()
        } else {
            // User cancelled or gave up - quit the app
            NSApplication.shared.terminate(nil)
        }
    }
}

@available(macOS 13, *)
private final class SetupPlaceholderViewController: NSViewController {
    private let diskImagePath: URL
    private let reason: ProvisioningPreflightResult.Reason

    init(diskImagePath: URL, reason: ProvisioningPreflightResult.Reason) {
        self.diskImagePath = diskImagePath
        self.reason = reason
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()

        let title = NSTextField(labelWithString: "Welcome to WinRun")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let description = NSTextField(wrappingLabelWithString: """
        WinRun needs a Windows ARM64 VM to run Windows apps.
        """
        )
        description.font = .systemFont(ofSize: 13)

        let reasonText: String = switch reason {
        case .diskImageMissing:
            "No Windows VM disk image was found."
        case .diskImageIsDirectory:
            "The configured VM disk image path points to a directory."
        }

        let details = NSTextField(wrappingLabelWithString: """
        \(reasonText)

        Expected disk image at:
        \(diskImagePath.path)
        """
        )
        details.font = .systemFont(ofSize: 12)
        details.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString: """
        Setup UI is coming next. For now you can provision Windows via:

          winrun init
        """
        )
        hint.font = .systemFont(ofSize: 12)

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded

        for subview in [title, description, details, hint, quitButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            description.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            description.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            description.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            details.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 12),
            details.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            hint.topAnchor.constraint(equalTo: details.bottomAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            quitButton.topAnchor.constraint(greaterThanOrEqualTo: hint.bottomAnchor, constant: 20),
            quitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            quitButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
