import AppKit
import Foundation
import WinRunSetup

/// Setup wizard screen for displaying provisioning progress.
///
/// This view controller is driven by `ProvisioningProgress` updates from `WinRunSetup`.
@available(macOS 13, *)
final class InstallProgressViewController: NSViewController {
    // MARK: - UI

    private let titleLabel = NSTextField(labelWithString: "Installing Windows")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let etaLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let phasesStack = NSStackView()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // MARK: - State

    private var phaseLabels: [ProvisioningPhase: NSTextField] = [:]
    private var startedAt = Date()
    private var lastProgress: ProvisioningProgress?

    /// Called after the user confirms cancellation.
    var onCancelRequested: (() -> Void)?

    override func loadView() {
        view = NSView()

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor

        etaLabel.font = .systemFont(ofSize: 12)
        etaLabel.textColor = .secondaryLabelColor
        etaLabel.stringValue = ""

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.controlSize = .regular

        phasesStack.orientation = .vertical
        phasesStack.alignment = .leading
        phasesStack.spacing = 6

        cancelButton.target = self
        cancelButton.action = #selector(confirmCancel)
        cancelButton.bezelStyle = .rounded

        for subview in [titleLabel, statusLabel, progressIndicator, etaLabel, phasesStack, cancelButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            progressIndicator.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            etaLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 8),
            etaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            etaLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            phasesStack.topAnchor.constraint(equalTo: etaLabel.bottomAnchor, constant: 18),
            phasesStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            phasesStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            cancelButton.topAnchor.constraint(greaterThanOrEqualTo: phasesStack.bottomAnchor, constant: 20),
            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])

        rebuildPhaseList()
        apply(progress: ProvisioningProgress(phase: .validatingISO, overallProgress: 0, message: "Ready to start"))
    }

    // MARK: - Public API

    func start() {
        startedAt = Date()
        lastProgress = nil
        apply(progress: ProvisioningProgress(phase: .validatingISO, overallProgress: 0, message: "Starting setup…"))
    }

    func apply(progress: ProvisioningProgress) {
        lastProgress = progress
        statusLabel.stringValue = progress.message
        progressIndicator.doubleValue = progress.overallProgress
        updatePhaseHighlight(activePhase: progress.phase)
        updateEstimatedTimeRemaining(progress: progress)
        cancelButton.isEnabled = !progress.phase.isTerminal
    }

    // MARK: - Phase List

    private func rebuildPhaseList() {
        phasesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        phaseLabels.removeAll()

        let phases: [ProvisioningPhase] = [
            .validatingISO,
            .creatingDisk,
            .installingWindows,
            .postInstallProvisioning,
            .creatingSnapshot,
        ]

        for phase in phases {
            let label = NSTextField(labelWithString: "• \(phase.displayName)")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            phaseLabels[phase] = label
            phasesStack.addArrangedSubview(label)
        }
    }

    private func updatePhaseHighlight(activePhase: ProvisioningPhase) {
        for (phase, label) in phaseLabels {
            if phase == activePhase {
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                label.textColor = .labelColor
            } else {
                label.font = .systemFont(ofSize: 12)
                label.textColor = .secondaryLabelColor
            }
        }
    }

    // MARK: - Estimated Time Remaining

    private func updateEstimatedTimeRemaining(progress: ProvisioningProgress) {
        if let seconds = progress.estimatedSecondsRemaining {
            etaLabel.stringValue = "Estimated time remaining: \(formatDuration(seconds: seconds))"
            return
        }

        // Best-effort estimate based on overall progress and elapsed time.
        // This is intentionally conservative and only shown once progress is non-trivial.
        let overall = progress.overallProgress
        guard overall >= 0.05 else {
            etaLabel.stringValue = ""
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let estimatedTotal = elapsed / max(overall, 0.001)
        let remaining = max(0, estimatedTotal - elapsed)
        etaLabel.stringValue = "Estimated time remaining: \(formatDuration(seconds: Int(remaining.rounded())))"
    }

    private func formatDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let rem = seconds % 60
        if minutes < 60 { return "\(minutes)m \(rem)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }

    // MARK: - Cancel

    @objc private func confirmCancel() {
        guard let progress = lastProgress, !progress.phase.isTerminal else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cancel setup?"
        alert.informativeText = "Cancelling will stop the Windows installation. You can retry later."
        alert.addButton(withTitle: "Cancel Setup")
        alert.addButton(withTitle: "Continue")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        onCancelRequested?()
    }
}
