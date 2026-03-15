import AppKit
import Foundation
import WinRunSetup

/// Setup wizard screen for manual installer fallback.
@available(macOS 13, *)
final class ManualInstallViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Manual Windows installation")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: """
    Automated launch could not continue. You can launch the installer VM manually, complete Windows setup,
    then return here and click "I finished".
    """)
    private let statusLabel = NSTextField(wrappingLabelWithString: "Checking installer prerequisites...")
    private let checksLabel = NSTextField(wrappingLabelWithString: "")
    private let launchButton = NSButton(title: "Launch installer", target: nil, action: nil)
    private let finishButton = NSButton(title: "I finished installing Windows", target: nil, action: nil)
    private let chooseISOButton = NSButton(title: "Choose a different ISO...", target: nil, action: nil)
    private let diagnosticsTitleLabel = NSTextField(labelWithString: "Diagnostics")
    private let diagnosticsScrollView = NSScrollView()
    private let diagnosticsTextView = NSTextView()

    private var diagnosticsLines: [String] = []

    var onLaunchInstaller: (() -> Void)?
    var onFinishRequested: (() -> Void)?
    var onChooseDifferentISO: (() -> Void)?

    override func loadView() {
        view = NSView()
        configureUI()
        installSubviews()
        activateConstraints()
    }

    func updatePreflight(_ preflight: InstallerPreflightResult) {
        checksLabel.stringValue = preflight.checks.map { check in
            let marker: String = switch check.status {
            case .ready: "[OK]"
            case .warning: "[WARN]"
            case .missing: "[MISSING]"
            }
            return "\(marker) \(check.name): \(check.details)"
        }.joined(separator: "\n")

        if preflight.isLaunchable {
            setStatus("Prerequisites are ready. Launch the installer VM.", isError: false)
            launchButton.isEnabled = true
        } else {
            setStatus(preflight.summary, isError: true)
            launchButton.isEnabled = false
        }
    }

    func appendDiagnostic(_ line: String) {
        diagnosticsLines.append(line)
        if diagnosticsLines.count > 600 {
            diagnosticsLines.removeFirst(diagnosticsLines.count - 600)
        }
        diagnosticsTextView.string = diagnosticsLines.joined(separator: "\n")
        diagnosticsTextView.scrollToEndOfDocument(nil)
    }

    func setStatus(_ message: String, isError: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func configureUI() {
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        checksLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        checksLabel.textColor = .secondaryLabelColor
        checksLabel.maximumNumberOfLines = 0

        launchButton.target = self
        launchButton.action = #selector(didRequestLaunchInstaller)
        launchButton.bezelStyle = .rounded
        launchButton.isEnabled = false

        finishButton.target = self
        finishButton.action = #selector(didRequestFinish)
        finishButton.bezelStyle = .rounded

        chooseISOButton.target = self
        chooseISOButton.action = #selector(didRequestChooseDifferentISO)
        chooseISOButton.bezelStyle = .rounded

        diagnosticsTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        diagnosticsTextView.isEditable = false
        diagnosticsTextView.isSelectable = true
        diagnosticsTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsTextView.backgroundColor = .textBackgroundColor
        diagnosticsTextView.textColor = .labelColor
        diagnosticsTextView.string = ""

        diagnosticsScrollView.borderType = .bezelBorder
        diagnosticsScrollView.hasVerticalScroller = true
        diagnosticsScrollView.hasHorizontalScroller = false
        diagnosticsScrollView.documentView = diagnosticsTextView
    }

    private func installSubviews() {
        let subviews: [NSView] = [
            titleLabel,
            descriptionLabel,
            statusLabel,
            checksLabel,
            launchButton,
            finishButton,
            chooseISOButton,
            diagnosticsTitleLabel,
            diagnosticsScrollView,
        ]
        subviews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
    }

    private func activateConstraints() {
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            checksLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            checksLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            checksLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            launchButton.topAnchor.constraint(equalTo: checksLabel.bottomAnchor, constant: 12),
            launchButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            finishButton.centerYAnchor.constraint(equalTo: launchButton.centerYAnchor),
            finishButton.leadingAnchor.constraint(equalTo: launchButton.trailingAnchor, constant: 10),

            chooseISOButton.centerYAnchor.constraint(equalTo: launchButton.centerYAnchor),
            chooseISOButton.leadingAnchor.constraint(equalTo: finishButton.trailingAnchor, constant: 10),

            diagnosticsTitleLabel.topAnchor.constraint(equalTo: launchButton.bottomAnchor, constant: 16),
            diagnosticsTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            diagnosticsTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            diagnosticsScrollView.topAnchor.constraint(equalTo: diagnosticsTitleLabel.bottomAnchor, constant: 8),
            diagnosticsScrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            diagnosticsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            diagnosticsScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            diagnosticsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
    }

    @objc private func didRequestLaunchInstaller() {
        onLaunchInstaller?()
    }

    @objc private func didRequestFinish() {
        onFinishRequested?()
    }

    @objc private func didRequestChooseDifferentISO() {
        onChooseDifferentISO?()
    }
}
