import AppKit
import Foundation

/// First screen of the setup wizard: welcomes the user and describes requirements.
@available(macOS 13, *)
final class WelcomeViewController: NSViewController {
    private static let microsoftWindowsDownloadURL = URL(string: "https://www.microsoft.com/software-download/windows11")!

    override func loadView() {
        view = NSView()

        let title = NSTextField(labelWithString: "Welcome to WinRun")
        title.font = .systemFont(ofSize: 26, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: """
        Run Windows apps seamlessly on your Mac.
        """
        )
        subtitle.font = .systemFont(ofSize: 14)

        let requirementsTitle = NSTextField(labelWithString: "What you’ll need")
        requirementsTitle.font = .systemFont(ofSize: 15, weight: .semibold)

        let requirementsBody = NSTextField(wrappingLabelWithString: """
        - A Windows 11 ARM64 installation ISO
        - ~64GB of free disk space for the VM (default)
        - Internet access during setup (drivers/agent install)
        """
        )
        requirementsBody.font = .systemFont(ofSize: 13)

        let recommendation = NSTextField(wrappingLabelWithString: """
        Recommended: Windows 11 IoT Enterprise LTSC 2024 ARM64 (best performance and least bloat).
        """
        )
        recommendation.font = .systemFont(ofSize: 12)
        recommendation.textColor = .secondaryLabelColor

        let downloadButton = NSButton(title: "Get Windows from Microsoft…", target: self, action: #selector(openMicrosoftDownload))
        downloadButton.bezelStyle = .rounded

        for subview in [title, subtitle, requirementsTitle, requirementsBody, recommendation, downloadButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            requirementsTitle.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22),
            requirementsTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            requirementsTitle.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            requirementsBody.topAnchor.constraint(equalTo: requirementsTitle.bottomAnchor, constant: 10),
            requirementsBody.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            requirementsBody.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            recommendation.topAnchor.constraint(equalTo: requirementsBody.bottomAnchor, constant: 12),
            recommendation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            recommendation.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            downloadButton.topAnchor.constraint(equalTo: recommendation.bottomAnchor, constant: 16),
            downloadButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            downloadButton.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
        ])
    }

    @objc private func openMicrosoftDownload() {
        NSWorkspace.shared.open(Self.microsoftWindowsDownloadURL)
    }
}
