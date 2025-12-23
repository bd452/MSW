import AppKit
import Foundation
import WinRunSetup

/// Setup wizard screen displayed after provisioning completes successfully.
@available(macOS 13, *)
final class SetupCompleteViewController: NSViewController {
    // MARK: - UI

    private let titleLabel = NSTextField(labelWithString: "Setup complete")
    private let messageLabel = NSTextField(wrappingLabelWithString: "Windows is ready to use.")
    private let diskUsageLabel = NSTextField(labelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let tipsTitleLabel = NSTextField(labelWithString: "Getting started")
    private let tipsBodyLabel = NSTextField(wrappingLabelWithString: "")
    private let learnMoreButton = NSButton(title: "Learn more…", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    // MARK: - State

    private let result: ProvisioningResult

    /// Called when the user taps "Done".
    var onDone: (() -> Void)?

    init(result: ProvisioningResult) {
        self.result = result
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        configureContent()
        installSubviews()
        activateConstraints()
    }

    private func configureContent() {
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor

        diskUsageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        diskUsageLabel.textColor = .labelColor
        diskUsageLabel.stringValue = "Disk usage: \(formatDiskUsage(bytes: result.diskUsageBytes))"

        detailsLabel.font = .systemFont(ofSize: 12)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.stringValue = formatDetails(result: result)

        tipsTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        tipsTitleLabel.textColor = .labelColor

        tipsBodyLabel.font = .systemFont(ofSize: 12)
        tipsBodyLabel.textColor = .secondaryLabelColor
        tipsBodyLabel.maximumNumberOfLines = 0
        tipsBodyLabel.stringValue = """
        - Double-click a .exe or .msi in Finder to run/install it in WinRun
        - Use the CLI: winrun \"C:\\Path\\To\\App.exe\" (or a macOS path under /Users)
        - After installing, WinRun can generate native macOS .app launchers for Windows apps
        """

        learnMoreButton.target = self
        learnMoreButton.action = #selector(openLearnMore)
        learnMoreButton.bezelStyle = .rounded

        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.bezelStyle = .rounded
    }

    private func installSubviews() {
        for subview in allSubviews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func activateConstraints() {
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            diskUsageLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            diskUsageLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            diskUsageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            detailsLabel.topAnchor.constraint(equalTo: diskUsageLabel.bottomAnchor, constant: 10),
            detailsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            tipsTitleLabel.topAnchor.constraint(equalTo: detailsLabel.bottomAnchor, constant: 16),
            tipsTitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tipsTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            tipsBodyLabel.topAnchor.constraint(equalTo: tipsTitleLabel.bottomAnchor, constant: 8),
            tipsBodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tipsBodyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            learnMoreButton.topAnchor.constraint(equalTo: tipsBodyLabel.bottomAnchor, constant: 14),
            learnMoreButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            doneButton.topAnchor.constraint(greaterThanOrEqualTo: learnMoreButton.bottomAnchor, constant: 20),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
    }

    private var allSubviews: [NSView] {
        [
            titleLabel,
            messageLabel,
            diskUsageLabel,
            detailsLabel,
            tipsTitleLabel,
            tipsBodyLabel,
            learnMoreButton,
            doneButton,
        ]
    }

    // MARK: - Formatting

    private func formatDiskUsage(bytes: UInt64?) -> String {
        guard let bytes else { return "Unavailable" }

        if bytes <= UInt64(Int64.max) {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            formatter.includesUnit = true
            formatter.isAdaptive = true
            return formatter.string(fromByteCount: Int64(bytes))
        }

        // Extremely defensive fallback (should never occur for our use case).
        let mb = bytes / (1024 * 1024)
        return "\(mb) MB"
    }

    private func formatDetails(result: ProvisioningResult) -> String {
        var parts: [String] = []
        if let windowsVersion = result.windowsVersion, !windowsVersion.isEmpty {
            parts.append("Windows: \(windowsVersion)")
        }
        if let agentVersion = result.agentVersion, !agentVersion.isEmpty {
            parts.append("WinRun Agent: \(agentVersion)")
        }
        parts.append("Disk image: \(result.diskImagePath.path)")
        return parts.joined(separator: "\n")
    }

    // MARK: - Actions

    @objc private func done() {
        onDone?()
    }

    @objc private func openLearnMore() {
        guard let url = URL(string: "https://github.com/winrun/winrun") else { return }
        NSWorkspace.shared.open(url)
    }
}
