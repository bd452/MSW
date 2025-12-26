import AppKit
import Foundation
import WinRunSetup
import WinRunShared

/// Setup wizard screen for displaying an actionable provisioning error.
@available(macOS 13, *)
final class SetupErrorViewController: NSViewController {
    enum RecoveryActionID: String {
        case retrySetup = "retry_setup"
        case chooseDifferentISO = "choose_different_iso"
        case contactSupport = "contact_support"
        case reviewDetails = "review_details"
    }

    struct RecoveryAction {
        let id: RecoveryActionID
        let title: String
        let help: String?
        let isPrimary: Bool
        let handler: (() -> Void)?

        /// Whether this action should be shown as enabled even without a handler.
        ///
        /// Use this for informational actions (e.g., "Review error details") that don't
        /// have a callback but should still be visible.
        let isInformational: Bool

        init(
            id: RecoveryActionID,
            title: String,
            help: String? = nil,
            isPrimary: Bool = false,
            handler: (() -> Void)? = nil,
            isInformational: Bool = false
        ) {
            self.id = id
            self.title = title
            self.help = help
            self.isPrimary = isPrimary
            self.handler = handler
            self.isInformational = isInformational

            // Enforce that primary actions have handlers
            if isPrimary && handler == nil {
                assertionFailure(
                    "Primary recovery action '\(id.rawValue)' must have a handler wired. "
                    + "This is likely a coordinator bug."
                )
            }
        }

        /// Whether this action's button should be enabled.
        var isEnabled: Bool {
            handler != nil || isInformational
        }
    }

    // MARK: - UI

    private let titleLabel = NSTextField(labelWithString: "Setup failed")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let actionsTitleLabel = NSTextField(labelWithString: "What you can do")
    private let actionsStack = NSStackView()
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)

    // MARK: - State

    private let error: Error
    private let failureContext: SetupFailureContext?
    private let recoveryActions: [RecoveryAction]

    private static let supportURL = URL(string: "https://github.com/winrun/winrun/issues")!

    /// Creates an error view controller with a basic error.
    init(
        error: Error,
        onRetrySetup: (() -> Void)? = nil,
        onChooseDifferentISO: (() -> Void)? = nil,
        onContactSupport: (() -> Void)? = nil,
        recoveryActions: [RecoveryAction] = []
    ) {
        self.error = error
        self.failureContext = nil
        self.recoveryActions = recoveryActions.isEmpty
            ? Self.defaultRecoveryActions(
                onRetrySetup: onRetrySetup,
                onChooseDifferentISO: onChooseDifferentISO,
                onContactSupport: onContactSupport
            )
            : recoveryActions
        super.init(nibName: nil, bundle: nil)
    }

    /// Creates an error view controller with rich failure context.
    init(
        failureContext: SetupFailureContext,
        onRetrySetup: (() -> Void)? = nil,
        onChooseDifferentISO: (() -> Void)? = nil,
        onRollback: (() -> Void)? = nil,
        onContactSupport: (() -> Void)? = nil
    ) {
        self.error = failureContext.error
        self.failureContext = failureContext
        self.recoveryActions = Self.recoveryActionsFromContext(
            failureContext,
            onRetrySetup: onRetrySetup,
            onChooseDifferentISO: onChooseDifferentISO,
            onRollback: onRollback,
            onContactSupport: onContactSupport
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.stringValue = "WinRun ran into a problem while setting up Windows."

        detailsLabel.font = .systemFont(ofSize: 12)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.stringValue = formatDetails(error: error)

        actionsTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        actionsTitleLabel.textColor = .labelColor

        actionsStack.orientation = .vertical
        actionsStack.alignment = .leading
        actionsStack.spacing = 10

        rebuildActions()

        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.bezelStyle = .rounded

        for subview in [titleLabel, summaryLabel, detailsLabel, actionsTitleLabel, actionsStack, quitButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            detailsLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            detailsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            actionsTitleLabel.topAnchor.constraint(equalTo: detailsLabel.bottomAnchor, constant: 16),
            actionsTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actionsTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            actionsStack.topAnchor.constraint(equalTo: actionsTitleLabel.bottomAnchor, constant: 8),
            actionsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            quitButton.topAnchor.constraint(greaterThanOrEqualTo: actionsStack.bottomAnchor, constant: 20),
            quitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            quitButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
    }

    private func rebuildActions() {
        actionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for action in recoveryActions {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4

            let button = NSButton(title: action.title, target: self, action: #selector(runRecoveryAction(_:)))
            // Keep to macOS 13-compatible styles. Emphasize primary action via default key + font weight.
            button.bezelStyle = .rounded
            button.keyEquivalent = action.isPrimary ? "\r" : ""
            if action.isPrimary {
                button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            }
            button.identifier = NSUserInterfaceItemIdentifier(action.id.rawValue)
            button.isEnabled = action.isEnabled

            row.addArrangedSubview(button)

            if let help = action.help, !help.isEmpty {
                let helpLabel = NSTextField(wrappingLabelWithString: help)
                helpLabel.font = .systemFont(ofSize: 12)
                helpLabel.textColor = .secondaryLabelColor
                helpLabel.maximumNumberOfLines = 0
                row.addArrangedSubview(helpLabel)
            }

            actionsStack.addArrangedSubview(row)
        }
    }

    private static func defaultRecoveryActions(
        onRetrySetup: (() -> Void)?,
        onChooseDifferentISO: (() -> Void)?,
        onContactSupport: (() -> Void)?
    ) -> [RecoveryAction] {
        let contact = onContactSupport ?? {
            NSWorkspace.shared.open(supportURL)
        }

        return [
            RecoveryAction(
                id: .retrySetup,
                title: "Retry setup",
                help: "Try again with the same settings. If this keeps failing, try a different ISO.",
                isPrimary: true,
                handler: onRetrySetup
            ),
            RecoveryAction(
                id: .chooseDifferentISO,
                title: "Choose a different Windows ISO…",
                help: "Some ISOs (e.g. Windows Server or non‑ARM64) won’t work well with WinRun.",
                isPrimary: false,
                handler: onChooseDifferentISO
            ),
            RecoveryAction(
                id: .contactSupport,
                title: "Contact support…",
                help: "Opens the WinRun issue tracker so you can include this error message.",
                isPrimary: false,
                handler: contact
            ),
            RecoveryAction(
                id: .reviewDetails,
                title: "Review error details",
                help: "Copy the error above into your support request. Also ensure you have enough free disk space.",
                isPrimary: false,
                handler: nil,
                isInformational: true
            ),
        ]
    }

    private func formatDetails(error: Error) -> String {
        // Use failure context for richer details if available
        if let context = failureContext {
            return formatContextDetails(context)
        }

        if let winRunError = error as? WinRunError {
            return winRunError.localizedDescription
        }

        let nsError = error as NSError
        if !nsError.localizedDescription.isEmpty {
            return nsError.localizedDescription
        }

        return String(describing: error)
    }

    private func formatContextDetails(_ context: SetupFailureContext) -> String {
        var parts: [String] = []

        // Summary
        parts.append(context.summary)

        // Phase info
        parts.append("Failed during: \(context.failedPhase.displayName)")

        // Disk space info if relevant
        if let freeSpace = context.freeDiskSpaceBytes {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append("Free disk space: \(formatter.string(fromByteCount: Int64(freeSpace)))")
        }

        // ISO info if available
        if let isoPath = context.isoPath {
            parts.append("ISO: \(isoPath.lastPathComponent)")
        }

        // Technical details
        parts.append("")
        parts.append("Technical details:")
        parts.append(context.technicalDetails)

        return parts.joined(separator: "\n")
    }

    private static func recoveryActionsFromContext(
        _ context: SetupFailureContext,
        onRetrySetup: (() -> Void)?,
        onChooseDifferentISO: (() -> Void)?,
        onRollback: (() -> Void)?,
        onContactSupport: (() -> Void)?
    ) -> [RecoveryAction] {
        var actions: [RecoveryAction] = []

        for suggestedAction in context.suggestedActions {
            switch suggestedAction {
            case .retry:
                actions.append(RecoveryAction(
                    id: .retrySetup,
                    title: suggestedAction.displayName,
                    help: suggestedAction.helpText,
                    isPrimary: actions.isEmpty,  // First action is primary
                    handler: onRetrySetup
                ))

            case .chooseDifferentISO:
                actions.append(RecoveryAction(
                    id: .chooseDifferentISO,
                    title: suggestedAction.displayName,
                    help: suggestedAction.helpText,
                    isPrimary: actions.isEmpty,
                    handler: onChooseDifferentISO
                ))

            case .rollback:
                if context.cleanupRecommended {
                    actions.append(RecoveryAction(
                        id: .retrySetup,
                        title: suggestedAction.displayName,
                        help: suggestedAction.helpText,
                        isPrimary: false,
                        handler: onRollback
                    ))
                }

            case .contactSupport:
                let handler = onContactSupport ?? { NSWorkspace.shared.open(supportURL) }
                actions.append(RecoveryAction(
                    id: .contactSupport,
                    title: suggestedAction.displayName,
                    help: suggestedAction.helpText,
                    isPrimary: false,
                    handler: handler
                ))

            default:
                // Informational actions without handlers
                actions.append(RecoveryAction(
                    id: .reviewDetails,
                    title: suggestedAction.displayName,
                    help: suggestedAction.helpText,
                    isPrimary: false,
                    handler: nil,
                    isInformational: true
                ))
            }
        }

        // Always add review details at the end
        actions.append(RecoveryAction(
            id: .reviewDetails,
            title: "Review error details",
            help: "Copy the error above into your support request.",
            isPrimary: false,
            handler: nil,
            isInformational: true
        ))

        return actions
    }

    @objc private func runRecoveryAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        guard let action = recoveryActions.first(where: { $0.id.rawValue == id }) else { return }
        action.handler?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
