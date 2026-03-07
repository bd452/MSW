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

// MARK: - QEMU Install Helper

/// Builds and launches a `qemu-system-aarch64` process for Windows installation.
enum QEMUInstallHelper {
    /// Discovers the QEMU binary by querying `brew --prefix` first, then
    /// falling back to a PATH-based `which` lookup. No hardcoded paths.
    static func findQEMU() -> URL? {
        if let brewPrefix = queryBrewPrefix() {
            let candidate = brewPrefix
                .appendingPathComponent("bin/qemu-system-aarch64")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return whichExecutable("qemu-system-aarch64")
    }

    /// Locates a QEMU share-directory file (e.g. firmware or vars template).
    /// Derives the path from the QEMU binary location, falling back to
    /// `brew --prefix qemu`.
    static func findQEMUShareFile(_ filename: String, qemuBinary: URL) -> URL? {
        let prefix = qemuBinary
            .deletingLastPathComponent() // bin/
            .deletingLastPathComponent() // prefix/
        let derived = prefix.appendingPathComponent("share/qemu/\(filename)")
        if FileManager.default.fileExists(atPath: derived.path) {
            return derived
        }

        if let brewQEMU = queryBrewPrefix(formula: "qemu") {
            let candidate = brewQEMU.appendingPathComponent("share/qemu/\(filename)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Creates a writable EFI variable store next to the disk image.
    /// Reuses an existing one so boot entries persist across retries.
    static func ensureEFIVariableStore(
        diskImagePath: URL,
        qemuBinary: URL
    ) throws -> URL {
        let nvramPath = diskImagePath
            .deletingPathExtension()
            .appendingPathExtension("qemu-nvram")

        if FileManager.default.fileExists(atPath: nvramPath.path) {
            return nvramPath
        }

        guard let varsTemplate = findQEMUShareFile("edk2-arm-vars.fd", qemuBinary: qemuBinary)
        else {
            throw QEMULaunchError.varsTemplateNotFound
        }

        let parentDir = nvramPath.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(
                at: parentDir, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: varsTemplate, to: nvramPath)
        return nvramPath
    }

    /// Finds the VirtIO driver ISO (bundled in app resources or in Application Support).
    static func findVirtIOISO(appSupportDir: URL) -> URL? {
        if let bundlePath = Bundle.main.url(forResource: "virtio-win", withExtension: "iso") {
            return bundlePath
        }
        let appSupportPath = appSupportDir.appendingPathComponent("virtio-win.iso")
        if FileManager.default.fileExists(atPath: appSupportPath.path) {
            return appSupportPath
        }
        return nil
    }

    /// Downloads the VirtIO driver ISO from Fedora's stable channel.
    /// The URL is read from the bundled `virtio-config.plist`, falling back
    /// to the well-known Fedora URL.
    static func downloadVirtIOISO(
        to directory: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let destination = directory.appendingPathComponent("virtio-win.iso")

        let defaultURL = "https://fedorapeople.org/groups/virt/virtio-win/"
            + "direct-downloads/stable-virtio/virtio-win.iso"

        var downloadURLString = defaultURL
        if let plistURL = Bundle.main.url(
            forResource: "virtio-config", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: plistURL),
           let urlStr = dict["VirtIODriversURL"] as? String
        {
            downloadURLString = urlStr
        }

        guard let url = URL(string: downloadURLString) else {
            completion(.failure(QEMULaunchError.virtioDownloadFailed))
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let tempURL,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                completion(.failure(QEMULaunchError.virtioDownloadFailed))
                return
            }
            do {
                let fm = FileManager.default
                if !fm.fileExists(atPath: directory.path) {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: tempURL, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    /// Discovers `swtpm` via PATH lookup.
    static func findSwtpm() -> URL? {
        whichExecutable("swtpm")
    }

    // MARK: - Windows 11 Hardware Check Bypass

    /// Autounattend XML that bypasses Windows 11 hardware checks (TPM, Secure Boot, RAM).
    /// Only the `windowsPE` pass is used so it doesn't automate the rest of setup.
    private static let bypassAutounattendXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend"
              xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup"
                   processorArchitecture="arm64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>2</Order>
              <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
            <RunSynchronousCommand wcm:action="add">
              <Order>3</Order>
              <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
        <component name="Microsoft-Windows-PnpCustomizationsWinPE"
                   processorArchitecture="arm64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1">
              <Path>D:\\viostor\\w11\\ARM64</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2">
              <Path>E:\\viostor\\w11\\ARM64</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="3">
              <Path>F:\\viostor\\w11\\ARM64</Path>
            </PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="4">
              <Path>G:\\viostor\\w11\\ARM64</Path>
            </PathAndCredentials>
          </DriverPaths>
        </component>
      </settings>
    </unattend>
    """

    /// Creates a small ISO containing `autounattend.xml` that bypasses
    /// Windows 11 hardware checks. Uses macOS's built-in `hdiutil`.
    static func createBypassISO(in directory: URL) throws -> URL {
        let isoPath = directory.appendingPathComponent("win11-bypass.iso")
        // Always recreate — the XML content may have changed between versions.
        try? FileManager.default.removeItem(at: isoPath)

        let stagingDir = directory.appendingPathComponent("bypass-staging")
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let xmlPath = stagingDir.appendingPathComponent("autounattend.xml")
        try bypassAutounattendXML.write(to: xmlPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = [
            "makehybrid",
            "-o", isoPath.path,
            stagingDir.path,
            "-iso", "-joliet",
            "-default-volume-name", "OEMDRV",
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        try? fm.removeItem(at: stagingDir)

        guard proc.terminationStatus == 0 else {
            throw QEMULaunchError.bypassISOCreationFailed
        }
        return isoPath
    }

    /// Result of a QEMU launch, including the process and a pipe for stderr.
    struct LaunchResult {
        let process: Process
        let stderrPipe: Pipe
    }

    /// Result of launching swtpm.
    struct SwtpmResult {
        let process: Process
        let socketPath: URL
    }

    /// Launches `swtpm` in socket mode to provide TPM 2.0 for QEMU.
    static func launchSwtpm(stateDir: URL) throws -> SwtpmResult {
        guard let swtpmPath = whichExecutable("swtpm") else {
            throw QEMULaunchError.swtpmNotFound
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: stateDir.path) {
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        }

        let socketPath = stateDir.appendingPathComponent("swtpm-sock")
        // Remove stale socket from a previous run.
        try? fm.removeItem(at: socketPath)

        let process = Process()
        process.executableURL = swtpmPath
        process.arguments = [
            "socket",
            "--tpmstate", "dir=\(stateDir.path)",
            "--ctrl", "type=unixio,path=\(socketPath.path)",
            "--tpm2",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Give swtpm a moment to create the socket.
        Thread.sleep(forTimeInterval: 0.5)
        return SwtpmResult(process: process, socketPath: socketPath)
    }

    /// Launches QEMU configured for Windows 11 ARM64 installation
    /// (ramfb + virtio-gpu, virtio-blk, usb-storage ISOs, TPM 2.0).
    static func launchInstallVM(
        qemuPath: URL,
        isoPath: URL,
        diskImagePath: URL,
        virtioISOPath: URL?,
        tpmSocketPath: URL? = nil
    ) throws -> LaunchResult {
        guard let firmware = findQEMUShareFile("edk2-aarch64-code.fd", qemuBinary: qemuPath)
        else {
            throw QEMULaunchError.firmwareNotFound
        }
        let nvram = try ensureEFIVariableStore(
            diskImagePath: diskImagePath, qemuBinary: qemuPath)

        let cpuCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        let memoryMB = 4096

        var args: [String] = [
            "-M", "virt,highmem=on",
            "-cpu", "host",
            "-accel", "hvf",
            "-m", "\(memoryMB)",
            "-smp", "\(cpuCount)",

            "-drive",
            "if=pflash,format=raw,file=\(firmware.path),readonly=on",
            "-drive",
            "if=pflash,format=raw,file=\(nvram.path)",

            "-device", "ramfb",
            "-device", "virtio-gpu-pci",

            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",

            "-drive",
            "file=\(diskImagePath.path),if=virtio,format=raw,discard=on",

            "-drive",
            "file=\(isoPath.path),media=cdrom,if=none,id=inst,readonly=on,file.locking=off",
            "-device", "usb-storage,drive=inst",

            "-nic", "user,model=virtio-net-pci,mac=52:54:00:12:34:56",
        ]

        if let tpmSocket = tpmSocketPath {
            args += [
                "-chardev", "socket,id=chrtpm,path=\(tpmSocket.path)",
                "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                "-device", "tpm-tis-device,tpmdev=tpm0",
            ]
        }

        if let virtioISO = virtioISOPath {
            args += [
                "-drive",
                "file=\(virtioISO.path),media=cdrom,if=none,id=virtio,readonly=on,file.locking=off",
                "-device", "usb-storage,drive=virtio",
            ]
        }

        // Attach bypass ISO to skip Windows 11 hardware checks (Secure Boot, TPM, RAM).
        let bypassDir = diskImagePath.deletingLastPathComponent()
        if let bypassISO = try? createBypassISO(in: bypassDir) {
            args += [
                "-drive",
                "file=\(bypassISO.path),media=cdrom,if=none,id=bypass,readonly=on",
                "-device", "usb-storage,drive=bypass",
            ]
        }

        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = qemuPath
        process.arguments = args
        process.standardError = stderrPipe
        try process.run()
        return LaunchResult(process: process, stderrPipe: stderrPipe)
    }

    // MARK: - Private Helpers

    /// Runs `brew --prefix [formula]` and returns the result as a URL.
    private static func queryBrewPrefix(formula: String? = nil) -> URL? {
        guard let brew = whichExecutable("brew") else { return nil }
        var arguments = ["--prefix"]
        if let formula { arguments.append(formula) }

        let proc = Process()
        proc.executableURL = brew
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(bytes: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Resolves an executable name via /usr/bin/which.
    private static func whichExecutable(_ name: String) -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(bytes: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

enum QEMULaunchError: LocalizedError {
    case firmwareNotFound
    case varsTemplateNotFound
    case swtpmNotFound
    case bypassISOCreationFailed
    case virtioDownloadFailed

    var errorDescription: String? {
        switch self {
        case .firmwareNotFound:
            return "QEMU EFI firmware (edk2-aarch64-code.fd) not found. "
                + "Reinstall QEMU with: brew reinstall qemu"
        case .varsTemplateNotFound:
            return "QEMU EFI variable template (edk2-arm-vars.fd) not found. "
                + "Reinstall QEMU with: brew reinstall qemu"
        case .swtpmNotFound:
            return "swtpm (software TPM) not found. Windows 11 requires TPM 2.0. "
                + "Install with: brew install swtpm"
        case .bypassISOCreationFailed:
            return "Failed to create Windows 11 hardware bypass ISO. "
                + "Check disk permissions in ~/Library/Application Support/WinRun/"
        case .virtioDownloadFailed:
            return "Failed to download VirtIO drivers ISO from Fedora. "
                + "Check your internet connection and try again."
        }
    }
}
