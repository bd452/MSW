import AppKit
import Foundation
import WinRunShared
 
/// Setup wizard screen for displaying an actionable provisioning error.
@available(macOS 13, *)
final class SetupErrorViewController: NSViewController {
    struct RecoveryAction {
        let title: String
        let help: String?
        let isPrimary: Bool
        let handler: (() -> Void)?
 
        init(title: String, help: String? = nil, isPrimary: Bool = false, handler: (() -> Void)? = nil) {
            self.title = title
            self.help = help
            self.isPrimary = isPrimary
            self.handler = handler
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
    private let recoveryActions: [RecoveryAction]
 
    init(error: Error, recoveryActions: [RecoveryAction] = []) {
        self.error = error
        self.recoveryActions = recoveryActions
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
 
        let actions = recoveryActions.isEmpty
            ? [
                RecoveryAction(
                    title: "Review the error details above",
                    help: "If this keeps happening, try a different Windows ISO or free up disk space.",
                    isPrimary: false,
                    handler: nil
                )
            ]
            : recoveryActions
 
        for action in actions {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
 
            let button = NSButton(title: action.title, target: self, action: #selector(runRecoveryAction(_:)))
            button.bezelStyle = action.isPrimary ? .prominentSquare : .rounded
            button.keyEquivalent = action.isPrimary ? "\r" : ""
            button.identifier = NSUserInterfaceItemIdentifier(action.title)
            button.isEnabled = action.handler != nil
 
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
 
    private func formatDetails(error: Error) -> String {
        if let winRunError = error as? WinRunError {
            return winRunError.localizedDescription
        }
 
        let nsError = error as NSError
        if !nsError.localizedDescription.isEmpty {
            return nsError.localizedDescription
        }
 
        return String(describing: error)
    }
 
    @objc private func runRecoveryAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        guard let action = recoveryActions.first(where: { $0.title == id }) else { return }
        action.handler?()
    }
 
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

