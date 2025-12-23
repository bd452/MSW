import AppKit
import Foundation
import WinRunShared

/// Routes WinRun.app startup into either the setup wizard or normal operation.
///
/// The real setup wizard UI is implemented incrementally. Until then, we present a
/// simple placeholder window that makes the required next step obvious.
@available(macOS 13, *)
final class SetupFlowController {
    private let logger: Logger
    private let preflight: ProvisioningPreflightResult

    private var window: NSWindow?

    init(
        preflight: ProvisioningPreflightResult,
        logger: Logger = StandardLogger(subsystem: "WinRunApp.SetupFlowController")
    ) {
        self.preflight = preflight
        self.logger = logger
    }

    func routeToSetupOrNormalOperation(normalOperation: () -> Void) {
        switch preflight {
        case .ready:
            normalOperation()

        case .needsSetup(let diskImagePath, let reason):
            logger.info("Routing to setup UI. diskImagePath=\(diskImagePath.path) reason=\(reason.rawValue)")
            presentSetupPlaceholder(diskImagePath: diskImagePath, reason: reason)
        }
    }

    private func presentSetupPlaceholder(diskImagePath: URL, reason: ProvisioningPreflightResult.Reason) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let controller: NSViewController
        switch reason {
        case .diskImageMissing:
            controller = WelcomeViewController()
        case .diskImageIsDirectory:
            controller = SetupPlaceholderViewController(
                diskImagePath: diskImagePath,
                reason: reason
            )
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "WinRun Setup"
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
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
