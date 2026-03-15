import Foundation
import WinRunShared

/// Builds and launches a `qemu-system-aarch64` process for Windows installation.
enum QEMUInstallHelper {
    /// Discovers the QEMU binary by querying `brew --prefix` first, then
    /// falling back to a PATH-based `which` lookup. No hardcoded paths.
    static func findQEMU() -> URL? {
        QEMUToolResolver.findQEMU()
    }

    /// Locates a QEMU share-directory file (e.g. firmware or vars template).
    /// Derives the path from the QEMU binary location, falling back to
    /// `brew --prefix qemu`.
    static func findQEMUShareFile(_ filename: String, qemuBinary: URL) -> URL? {
        QEMUToolResolver.findQEMUShareFile(filename, qemuBinary: qemuBinary)
    }

    /// Creates a writable EFI variable store next to the disk image.
    /// Reuses an existing one so boot entries persist across retries.
    static func ensureEFIVariableStore(
        diskImagePath: URL,
        qemuBinary: URL
    ) throws -> URL {
        guard let varsTemplate = findQEMUShareFile("edk2-arm-vars.fd", qemuBinary: qemuBinary)
        else {
            throw QEMULaunchError.varsTemplateNotFound
        }
        return try QEMUToolResolver.ensureEFIVariableStore(
            diskImagePath: diskImagePath,
            varsTemplate: varsTemplate
        )
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
            let urlStr = dict["VirtIODriversURL"] as? String {
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
        QEMUToolResolver.findSwtpm()
    }

    // MARK: - Windows 11 Hardware Check Bypass

    // swiftlint:disable line_length
    private static let bypassAutounattendXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend"
              xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

      <!-- WinPE: bypass hardware checks + load storage driver for installer -->
      <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
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
        <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\\viostor\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\\viostor\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\\viostor\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>G:\\viostor\\w11\\ARM64</Path></PathAndCredentials>
          </DriverPaths>
        </component>
      </settings>

      <!-- offlineServicing: inject VirtIO drivers (network, GPU, balloon) into the installed image before first boot -->
      <settings pass="offlineServicing">
        <component name="Microsoft-Windows-PnpCustomizationsNonWinPE" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <DriverPaths>
            <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\\NetKVM\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\\NetKVM\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\\NetKVM\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>G:\\NetKVM\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>D:\\viogpudo\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>E:\\viogpudo\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>F:\\viogpudo\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>G:\\viogpudo\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="9"><Path>D:\\Balloon\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="10"><Path>E:\\Balloon\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="11"><Path>F:\\Balloon\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="12"><Path>G:\\Balloon\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="13"><Path>D:\\vioser\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="14"><Path>E:\\vioser\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="15"><Path>F:\\vioser\\w11\\ARM64</Path></PathAndCredentials>
            <PathAndCredentials wcm:action="add" wcm:keyValue="16"><Path>G:\\vioser\\w11\\ARM64</Path></PathAndCredentials>
          </DriverPaths>
        </component>
      </settings>

      <!-- specialize: allow OOBE to proceed without network if driver injection didn't take -->
      <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <RunSynchronous>
            <RunSynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
            </RunSynchronousCommand>
          </RunSynchronous>
        </component>
      </settings>

    </unattend>
    """
    // swiftlint:enable line_length

    /// Creates a small ISO containing `autounattend.xml` that bypasses
    /// Windows 11 hardware checks. Uses macOS's built-in `hdiutil`.
    static func createBypassISO(in directory: URL) throws -> URL {
        let isoPath = directory.appendingPathComponent("win11-bypass.iso")
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

    struct LaunchResult {
        let process: Process
        let stderrPipe: Pipe
    }

    struct SwtpmResult {
        let process: Process
        let socketPath: URL
    }

    /// Launches `swtpm` in socket mode to provide TPM 2.0 for QEMU.
    static func launchSwtpm(stateDir: URL) throws -> SwtpmResult {
        guard let swtpmPath = QEMUToolResolver.findSwtpm() else {
            throw QEMULaunchError.swtpmNotFound
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: stateDir.path) {
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        }

        let socketPath = stateDir.appendingPathComponent("swtpm-sock")
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

        Thread.sleep(forTimeInterval: 0.5)
        return SwtpmResult(process: process, socketPath: socketPath)
    }

    /// Launches QEMU configured for Windows 11 ARM64 installation.
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
            "-drive", "if=pflash,format=raw,file=\(firmware.path),readonly=on",
            "-drive", "if=pflash,format=raw,file=\(nvram.path)",
            "-device", "ramfb",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
            "-drive", "file=\(diskImagePath.path),if=virtio,format=raw,discard=on",
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

    /// Launches QEMU for interactive maintenance — booting from the installed
    /// Windows disk without any ISO media attached.
    static func launchMaintenanceVM(
        diskImagePath: URL,
        virtioISOPath: URL? = nil
    ) throws -> LaunchResult {
        guard let qemuPath = findQEMU() else {
            throw QEMULaunchError.firmwareNotFound
        }
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
            "-drive", "if=pflash,format=raw,file=\(firmware.path),readonly=on",
            "-drive", "if=pflash,format=raw,file=\(nvram.path)",
            "-device", "ramfb",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
            "-drive", "file=\(diskImagePath.path),if=virtio,format=raw,discard=on",
            "-nic", "user,model=virtio-net-pci,mac=52:54:00:12:34:56",
        ]

        let tpmDir = diskImagePath.deletingLastPathComponent()
            .appendingPathComponent("swtpm-state")
        if let swtpm = try? launchSwtpm(stateDir: tpmDir) {
            args += [
                "-chardev", "socket,id=chrtpm,path=\(swtpm.socketPath.path)",
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

        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = qemuPath
        process.arguments = args
        process.standardError = stderrPipe
        try process.run()
        return LaunchResult(process: process, stderrPipe: stderrPipe)
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
