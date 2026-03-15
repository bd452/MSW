import AppKit
import Foundation
import WinRunSetup
import WinRunShared

/// Manual installation fallback screen that launches QEMU for Windows setup.
///
/// Apple's Virtualization.framework UEFI firmware cannot render graphics during
/// Windows boot (no ramfb equivalent). QEMU provides the display stack needed
/// for the installer. After installation with VirtIO drivers, the VM runs on
/// Virtualization.framework for normal operation.
final class ManualInstallViewController: NSViewController {
    // MARK: - UI

    private let titleLabel = NSTextField(labelWithString: "Manual Windows setup")
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString:
            "Automated setup isn't available yet for this flow. "
            + "A QEMU window will open for you to install Windows manually."
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let instructionsLabel = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Start Windows installer", target: nil, action: nil)
    private let chooseDifferentISOButton = NSButton(
        title: "Choose a different ISO", target: nil, action: nil)
    private let completeButton = NSButton(
        title: "I finished manual installation", target: nil, action: nil)

    // MARK: - State

    private let isoPath: URL?
    private let diskImagePath: URL
    private var qemuProcess: Process?
    private var swtpmProcess: Process?

    var onComplete: (() -> Void)?
    var onChooseDifferentISO: (() -> Void)?

    init(isoPath: URL?, diskImagePath: URL) {
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        terminateProcesses()
    }

    override func loadView() {
        view = NSView()
        configureUI()
        installSubviews()
        activateConstraints()
    }

    // MARK: - UI Setup

    private func configureUI() {
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.isSelectable = true

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isSelectable = true

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.isSelectable = true

        detailsLabel.font = .systemFont(ofSize: 12)
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.maximumNumberOfLines = 0
        detailsLabel.isSelectable = true
        detailsLabel.stringValue = """
        ISO: \(isoPath?.lastPathComponent ?? "Not selected")
        Disk image: \(diskImagePath.path)
        """

        instructionsLabel.font = .systemFont(ofSize: 12)
        instructionsLabel.textColor = .secondaryLabelColor
        instructionsLabel.maximumNumberOfLines = 0
        instructionsLabel.isSelectable = true
        instructionsLabel.stringValue = """
        During Windows Setup:
        1. Hardware checks (TPM, Secure Boot) are bypassed automatically.
        2. At the drive/partition screen, if no drives appear, click
           "Load driver" → browse VirtIO ISO → viostor → w11 → ARM64.
        3. Install Windows to the VirtIO disk that appears.
        4. After Windows boots, install remaining VirtIO drivers
           (GPU, network) from the driver ISO.
        5. Shut down Windows, close QEMU, then click "I finished" below.
        """

        startButton.target = self
        startButton.action = #selector(startManualInstall)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        chooseDifferentISOButton.target = self
        chooseDifferentISOButton.action = #selector(chooseDifferentISO)
        chooseDifferentISOButton.bezelStyle = .rounded
        chooseDifferentISOButton.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        completeButton.target = self
        completeButton.action = #selector(completeManualInstall)
        completeButton.bezelStyle = .rounded
        completeButton.isEnabled = false

        refreshStatus()
    }

    private func refreshStatus() {
        var missing: [String] = []
        if QEMUInstallHelper.findQEMU() == nil {
            missing.append("qemu (brew install qemu)")
        }
        if QEMUInstallHelper.findSwtpm() == nil {
            missing.append("swtpm (brew install swtpm)")
        }

        if !missing.isEmpty {
            statusLabel.stringValue =
                "Missing required tools:\n" + missing.joined(separator: "\n")
            statusLabel.textColor = .systemRed
            startButton.isEnabled = false
        } else if isoPath == nil {
            statusLabel.stringValue = "Select an ISO to continue manual setup."
            statusLabel.textColor = .secondaryLabelColor
            startButton.isEnabled = false
        } else {
            statusLabel.stringValue = "Ready to start Windows installation via QEMU."
            statusLabel.textColor = .secondaryLabelColor
            startButton.isEnabled = true
        }
    }

    private func installSubviews() {
        let subviews: [NSView] = [
            titleLabel, subtitleLabel, detailsLabel, statusLabel,
            instructionsLabel, startButton, chooseDifferentISOButton, completeButton,
        ]
        for subview in subviews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
    }

    private func activateConstraints() {
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            detailsLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            detailsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: detailsLabel.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            instructionsLabel.topAnchor.constraint(
                equalTo: statusLabel.bottomAnchor, constant: 12),
            instructionsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            instructionsLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -24),

            startButton.topAnchor.constraint(
                equalTo: instructionsLabel.bottomAnchor, constant: 16),
            startButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            chooseDifferentISOButton.centerYAnchor.constraint(
                equalTo: startButton.centerYAnchor),
            chooseDifferentISOButton.leadingAnchor.constraint(
                equalTo: startButton.trailingAnchor, constant: 10),
            chooseDifferentISOButton.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            completeButton.topAnchor.constraint(
                greaterThanOrEqualTo: startButton.bottomAnchor, constant: 20),
            completeButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -24),
            completeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Actions

    @objc private func startManualInstall() {
        guard qemuProcess == nil else {
            statusLabel.stringValue = "QEMU is already running."
            return
        }
        guard let isoPath else {
            statusLabel.stringValue = "No ISO selected."
            statusLabel.textColor = .systemRed
            return
        }
        guard let qemuPath = QEMUInstallHelper.findQEMU() else {
            statusLabel.stringValue =
                "qemu-system-aarch64 not found.\nInstall with: brew install qemu"
            statusLabel.textColor = .systemRed
            return
        }

        let appSupportDir = diskImagePath.deletingLastPathComponent()

        // Check for VirtIO ISO; download if missing.
        if let existingISO = QEMUInstallHelper.findVirtIOISO(appSupportDir: appSupportDir) {
            launchQEMU(qemuPath: qemuPath, isoPath: isoPath, virtioISOPath: existingISO)
        } else {
            startButton.isEnabled = false
            statusLabel.stringValue = "Downloading VirtIO drivers (~500 MB)..."
            statusLabel.textColor = .secondaryLabelColor

            QEMUInstallHelper.downloadVirtIOISO(to: appSupportDir) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let path):
                        self.launchQEMU(
                            qemuPath: qemuPath, isoPath: isoPath, virtioISOPath: path)
                    case .failure(let error):
                        self.statusLabel.stringValue =
                            "VirtIO download failed: \(error.localizedDescription)\n"
                            + "You can continue without VirtIO drivers, but the disk "
                            + "may not appear during Windows Setup."
                        self.statusLabel.textColor = .systemOrange
                        self.startButton.isEnabled = true
                        // Let the user try anyway without VirtIO.
                        self.launchQEMU(
                            qemuPath: qemuPath, isoPath: isoPath, virtioISOPath: nil)
                    }
                }
            }
        }
    }

    private func launchQEMU(qemuPath: URL, isoPath: URL, virtioISOPath: URL?) {
        do {
            let tpmDir = diskImagePath.deletingLastPathComponent()
                .appendingPathComponent("tpm")
            let tpmResult = try QEMUInstallHelper.launchSwtpm(stateDir: tpmDir)
            swtpmProcess = tpmResult.process

            let result = try QEMUInstallHelper.launchInstallVM(
                qemuPath: qemuPath,
                isoPath: isoPath,
                diskImagePath: diskImagePath,
                virtioISOPath: virtioISOPath,
                tpmSocketPath: tpmResult.socketPath
            )
            let process = result.process
            let stderrPipe = result.stderrPipe
            qemuProcess = process

            startButton.isEnabled = false
            statusLabel.stringValue = "QEMU is running. Complete Windows Setup in the QEMU window."
            statusLabel.textColor = .systemGreen
            completeButton.isEnabled = true

            DispatchQueue.global(qos: .utility).async { [weak self] in
                process.waitUntilExit()

                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = (String(bytes: stderrData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.terminateSwtpm()
                    self.qemuProcess = nil
                    let code = process.terminationStatus
                    if code == 0 {
                        self.statusLabel.stringValue =
                            "QEMU exited normally. "
                            + "If installation is complete, click \"I finished\"."
                        self.statusLabel.textColor = .secondaryLabelColor
                    } else {
                        var message = "QEMU exited with code \(code)."
                        if !stderrText.isEmpty {
                            let truncated = String(stderrText.suffix(500))
                            message += "\n\n\(truncated)"
                        }
                        self.statusLabel.stringValue = message
                        self.statusLabel.textColor = .systemOrange
                    }
                    self.startButton.isEnabled = true
                }
            }
        } catch {
            terminateSwtpm()
            statusLabel.stringValue = "Failed to launch QEMU: \(error.localizedDescription)"
            statusLabel.textColor = .systemRed
            startButton.isEnabled = true
        }
    }

    @objc private func chooseDifferentISO() {
        terminateProcesses()
        onChooseDifferentISO?()
    }

    @objc private func completeManualInstall() {
        terminateProcesses()
        onComplete?()
    }

    private func terminateProcesses() {
        if let process = qemuProcess, process.isRunning { process.terminate() }
        qemuProcess = nil
        terminateSwtpm()
    }

    private func terminateSwtpm() {
        if let process = swtpmProcess, process.isRunning { process.terminate() }
        swtpmProcess = nil
    }
}
