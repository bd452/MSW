import Foundation
import WinRunShared

// MARK: - Installer Preflight Models

public struct InstallerPrerequisiteCheck: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case ready
        case warning
        case missing
    }

    public let name: String
    public let status: Status
    public let details: String

    public init(name: String, status: Status, details: String) {
        self.name = name
        self.status = status
        self.details = details
    }
}

public struct InstallerPreflightResult: Sendable, Equatable {
    public let checks: [InstallerPrerequisiteCheck]
    public let blockingIssues: [String]
    public let warnings: [String]

    public init(
        checks: [InstallerPrerequisiteCheck],
        blockingIssues: [String],
        warnings: [String]
    ) {
        self.checks = checks
        self.blockingIssues = blockingIssues
        self.warnings = warnings
    }

    public var isLaunchable: Bool {
        blockingIssues.isEmpty
    }

    public var summary: String {
        if isLaunchable {
            return "Installer prerequisites are ready."
        }
        return blockingIssues.joined(separator: " ")
    }
}

// MARK: - Launch Session

public final class InstallerLaunchSession: @unchecked Sendable {
    private let qemuProcess: Process
    private let swtpmProcess: Process?
    private let cleanup: @Sendable () -> Void
    private let lock = NSLock()
    private var didCleanup = false

    init(
        qemuProcess: Process,
        swtpmProcess: Process?,
        cleanup: @escaping @Sendable () -> Void
    ) {
        self.qemuProcess = qemuProcess
        self.swtpmProcess = swtpmProcess
        self.cleanup = cleanup
    }

    deinit {
        terminate()
        performCleanupIfNeeded()
    }

    public var isRunning: Bool {
        qemuProcess.isRunning
    }

    public func terminate() {
        if qemuProcess.isRunning {
            qemuProcess.terminate()
        }
        if let swtpmProcess, swtpmProcess.isRunning {
            swtpmProcess.terminate()
        }
    }

    public func waitForExit(
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> Int32 {
        // Unit tests may inject a non-launched Process instance.
        guard qemuProcess.processIdentifier != 0 else {
            performCleanupIfNeeded()
            return 0
        }

        while qemuProcess.isRunning {
            if isCancelled() || Task.isCancelled {
                terminate()
                performCleanupIfNeeded()
                throw WinRunError.cancelled
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // Give the TPM helper a brief chance to stop cleanly.
        if let swtpmProcess, swtpmProcess.isRunning {
            swtpmProcess.terminate()
        }

        performCleanupIfNeeded()
        return qemuProcess.terminationStatus
    }

    private func performCleanupIfNeeded() {
        lock.lock()
        if didCleanup {
            lock.unlock()
            return
        }
        didCleanup = true
        lock.unlock()
        cleanup()
    }
}

final class InstallerSessionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: InstallerLaunchSession?

    func set(_ session: InstallerLaunchSession) {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }

    func cancel() {
        lock.lock()
        let current = session
        lock.unlock()
        current?.terminate()
    }
}

// MARK: - Launcher Protocol

public protocol InstallerLaunchHelping: Sendable {
    func preflight(
        configuration: ProvisioningConfiguration,
        vmConfiguration: ProvisioningVMConfiguration,
        resourcesDirectory: URL?
    ) -> InstallerPreflightResult

    func launchInstaller(
        configuration: ProvisioningConfiguration,
        vmConfiguration: ProvisioningVMConfiguration,
        resourcesDirectory: URL?,
        outputHandler: @escaping @Sendable (String) -> Void
    ) throws -> InstallerLaunchSession
}

// MARK: - QEMU Installer Helper

public final class QEMUInstallHelper: InstallerLaunchHelping {
    public init() {}

    public func preflight(
        configuration: ProvisioningConfiguration,
        vmConfiguration: ProvisioningVMConfiguration,
        resourcesDirectory: URL?
    ) -> InstallerPreflightResult {
        let resolution = resolveLaunchContext(
            configuration: configuration,
            vmConfiguration: vmConfiguration,
            resourcesDirectory: resourcesDirectory
        )
        return InstallerPreflightResult(
            checks: resolution.checks,
            blockingIssues: resolution.blockingIssues,
            warnings: resolution.warnings
        )
    }

    // swiftlint:disable:next function_body_length
    public func launchInstaller(
        configuration: ProvisioningConfiguration,
        vmConfiguration: ProvisioningVMConfiguration,
        resourcesDirectory: URL?,
        outputHandler: @escaping @Sendable (String) -> Void
    ) throws -> InstallerLaunchSession {
        let resolution = resolveLaunchContext(
            configuration: configuration,
            vmConfiguration: vmConfiguration,
            resourcesDirectory: resourcesDirectory
        )

        guard resolution.blockingIssues.isEmpty,
              let qemuPath = resolution.qemuPath,
              let swtpmPath = resolution.swtpmPath,
              let firmwareCodeURL = resolution.firmwareCodeURL,
              let firmwareVarsTemplateURL = resolution.firmwareVarsTemplateURL,
              let diskURL = resolution.diskURL else {
            throw WinRunError.installerLaunchFailed(
                reason: resolution.blockingIssues.joined(separator: " ")
            )
        }

        let nvramURL = diskURL.deletingPathExtension().appendingPathExtension("nvram.fd")
        if !FileManager.default.fileExists(atPath: nvramURL.path) {
            try FileManager.default.copyItem(at: firmwareVarsTemplateURL, to: nvramURL)
        }

        let swtpmStateDirectory = diskURL.deletingPathExtension().appendingPathExtension("swtpm")
        if !FileManager.default.fileExists(atPath: swtpmStateDirectory.path) {
            try FileManager.default.createDirectory(
                at: swtpmStateDirectory,
                withIntermediateDirectories: true
            )
        }

        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winrun-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        let swtpmSocketURL = runtimeDirectory.appendingPathComponent("swtpm.sock")

        let swtpmProcess = Process()
        swtpmProcess.executableURL = URL(fileURLWithPath: swtpmPath)
        swtpmProcess.arguments = [
            "socket",
            "--tpmstate", "dir=\(swtpmStateDirectory.path)",
            "--ctrl", "type=unixio,path=\(swtpmSocketURL.path)",
            "--tpm2"
        ]
        let swtpmOutput = Pipe()
        let swtpmError = Pipe()
        swtpmProcess.standardOutput = swtpmOutput
        swtpmProcess.standardError = swtpmError
        do {
            try swtpmProcess.run()
        } catch {
            try? FileManager.default.removeItem(at: runtimeDirectory)
            throw WinRunError.installerLaunchFailed(
                reason: "Failed to start swtpm: \(error.localizedDescription)"
            )
        }

        let swtpmStdoutPump = OutputLinePump(prefix: "[swtpm] ", outputHandler: outputHandler)
        let swtpmStderrPump = OutputLinePump(prefix: "[swtpm] ", outputHandler: outputHandler)
        swtpmStdoutPump.attach(to: swtpmOutput.fileHandleForReading)
        swtpmStderrPump.attach(to: swtpmError.fileHandleForReading)

        guard waitForSocket(at: swtpmSocketURL, timeoutSeconds: 5) else {
            swtpmProcess.terminate()
            throw WinRunError.installerLaunchFailed(
                reason: "swtpm did not become ready before launch timeout."
            )
        }

        let qemuProcess = Process()
        qemuProcess.executableURL = URL(fileURLWithPath: qemuPath)
        qemuProcess.arguments = makeQEMUArguments(
            configuration: configuration,
            vmConfiguration: vmConfiguration,
            diskURL: diskURL,
            firmwareCodeURL: firmwareCodeURL,
            nvramURL: nvramURL,
            swtpmSocketURL: swtpmSocketURL
        )
        let qemuOutput = Pipe()
        let qemuError = Pipe()
        qemuProcess.standardOutput = qemuOutput
        qemuProcess.standardError = qemuError
        do {
            try qemuProcess.run()
        } catch {
            swtpmProcess.terminate()
            qemuOutput.fileHandleForReading.readabilityHandler = nil
            qemuError.fileHandleForReading.readabilityHandler = nil
            swtpmOutput.fileHandleForReading.readabilityHandler = nil
            swtpmError.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: runtimeDirectory)
            throw WinRunError.installerLaunchFailed(
                reason: "Failed to start qemu-system-aarch64: \(error.localizedDescription)"
            )
        }

        let qemuStdoutPump = OutputLinePump(prefix: "[qemu] ", outputHandler: outputHandler)
        let qemuStderrPump = OutputLinePump(prefix: "[qemu] ", outputHandler: outputHandler)
        qemuStdoutPump.attach(to: qemuOutput.fileHandleForReading)
        qemuStderrPump.attach(to: qemuError.fileHandleForReading)

        return InstallerLaunchSession(
            qemuProcess: qemuProcess,
            swtpmProcess: swtpmProcess,
            cleanup: {
                qemuOutput.fileHandleForReading.readabilityHandler = nil
                qemuError.fileHandleForReading.readabilityHandler = nil
                swtpmOutput.fileHandleForReading.readabilityHandler = nil
                swtpmError.fileHandleForReading.readabilityHandler = nil
                try? FileManager.default.removeItem(at: runtimeDirectory)
            }
        )
    }

    private struct ResolutionResult {
        let checks: [InstallerPrerequisiteCheck]
        let blockingIssues: [String]
        let warnings: [String]
        let qemuPath: String?
        let swtpmPath: String?
        let firmwareCodeURL: URL?
        let firmwareVarsTemplateURL: URL?
        let diskURL: URL?
    }

    // swiftlint:disable:next function_body_length
    private func resolveLaunchContext(
        configuration: ProvisioningConfiguration,
        vmConfiguration: ProvisioningVMConfiguration,
        resourcesDirectory: URL?
    ) -> ResolutionResult {
        var checks: [InstallerPrerequisiteCheck] = []
        var blockingIssues: [String] = []
        var warnings: [String] = []

        let diskURL = vmConfiguration.storageDevices.first(where: { $0.type == .disk })?.path
            ?? configuration.diskImagePath
        let diskDirectory = diskURL.deletingLastPathComponent()
        let diskWritable = ensureWritableDirectory(diskDirectory)
        checks.append(
            InstallerPrerequisiteCheck(
                name: "Disk path",
                status: diskWritable ? .ready : .missing,
                details: diskWritable
                    ? "Writable: \(diskDirectory.path)"
                    : "Not writable: \(diskDirectory.path)"
            )
        )
        if !diskWritable {
            blockingIssues.append("Disk path is not writable: \(diskDirectory.path).")
        }

        let qemuPath = locateBinary(
            name: "qemu-system-aarch64",
            candidates: [
                "/opt/homebrew/bin/qemu-system-aarch64",
                "/usr/local/bin/qemu-system-aarch64",
                "/usr/bin/qemu-system-aarch64",
            ]
        )
        checks.append(
            InstallerPrerequisiteCheck(
                name: "QEMU",
                status: qemuPath == nil ? .missing : .ready,
                details: qemuPath ?? "Install with: brew install qemu"
            )
        )
        if qemuPath == nil {
            blockingIssues.append("Missing qemu-system-aarch64 binary.")
        }

        let swtpmPath = locateBinary(
            name: "swtpm",
            candidates: [
                "/opt/homebrew/bin/swtpm",
                "/usr/local/bin/swtpm",
                "/usr/bin/swtpm",
            ]
        )
        checks.append(
            InstallerPrerequisiteCheck(
                name: "swtpm",
                status: swtpmPath == nil ? .missing : .ready,
                details: swtpmPath ?? "Install with: brew install swtpm"
            )
        )
        if swtpmPath == nil {
            blockingIssues.append("Missing swtpm binary.")
        }

        let firmwareCodeURL = locateFile(candidates: [
            "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
            "/usr/local/share/qemu/edk2-aarch64-code.fd",
            "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
            "/usr/share/edk2/aarch64/QEMU_EFI.fd",
        ])
        checks.append(
            InstallerPrerequisiteCheck(
                name: "EFI firmware code",
                status: firmwareCodeURL == nil ? .missing : .ready,
                details: firmwareCodeURL?.path ?? "EDK2 firmware file not found"
            )
        )
        if firmwareCodeURL == nil {
            blockingIssues.append("Missing EDK2 ARM64 firmware code file.")
        }

        let firmwareVarsTemplateURL = locateFile(candidates: [
            "/opt/homebrew/share/qemu/edk2-arm-vars.fd",
            "/usr/local/share/qemu/edk2-arm-vars.fd",
            "/usr/share/qemu-efi-aarch64/QEMU_VARS.fd",
            "/usr/share/edk2/aarch64/vars-template-pflash.raw",
        ])
        checks.append(
            InstallerPrerequisiteCheck(
                name: "EFI NVRAM template",
                status: firmwareVarsTemplateURL == nil ? .missing : .ready,
                details: firmwareVarsTemplateURL?.path ?? "NVRAM template file not found"
            )
        )
        if firmwareVarsTemplateURL == nil {
            blockingIssues.append("Missing EDK2 NVRAM template file.")
        }

        let virtioISOURL = locateVirtioISO(resourcesDirectory: resourcesDirectory)
        if let virtioISOURL {
            checks.append(
                InstallerPrerequisiteCheck(
                    name: "VirtIO drivers",
                    status: .ready,
                    details: virtioISOURL.path
                )
            )
        } else {
            let message =
                "VirtIO driver ISO not found; you can bundle it or download from " +
                "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
            checks.append(
                InstallerPrerequisiteCheck(
                    name: "VirtIO drivers",
                    status: .warning,
                    details: message
                )
            )
            warnings.append(message)
        }

        return ResolutionResult(
            checks: checks,
            blockingIssues: blockingIssues,
            warnings: warnings,
            qemuPath: qemuPath,
            swtpmPath: swtpmPath,
            firmwareCodeURL: firmwareCodeURL,
            firmwareVarsTemplateURL: firmwareVarsTemplateURL,
            diskURL: diskURL
        )
    }

    private func makeQEMUArguments(
        configuration: ProvisioningConfiguration,
        vmConfiguration: ProvisioningVMConfiguration,
        diskURL: URL,
        firmwareCodeURL: URL,
        nvramURL: URL,
        swtpmSocketURL: URL
    ) -> [String] {
        var args = [
            "-machine", "virt,accel=hvf,highmem=off",
            "-cpu", "host",
            "-smp", "\(max(2, vmConfiguration.cpuCount))",
            "-m", "\(max(4, vmConfiguration.memorySizeGB) * 1024)",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(firmwareCodeURL.path)",
            "-drive", "if=pflash,format=raw,file=\(nvramURL.path)",
            "-drive", "if=virtio,format=raw,file=\(diskURL.path)",
            "-cdrom", configuration.isoPath.path,
            "-boot", "order=d",
            "-display", "cocoa",
            "-chardev", "socket,id=chrtpm,path=\(swtpmSocketURL.path)",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
            "-device", "tpm-tis-device,tpmdev=tpm0",
        ]

        if let floppyURL = vmConfiguration.storageDevices.first(where: { $0.type == .floppy })?.path {
            args.append(contentsOf: [
                "-drive", "if=floppy,format=raw,readonly=on,file=\(floppyURL.path)"
            ])
        }

        return args
    }

    private func ensureWritableDirectory(_ directory: URL) -> Bool {
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            let probeURL = directory.appendingPathComponent(".winrun-write-probe-\(UUID().uuidString)")
            try Data("probe".utf8).write(to: probeURL, options: .atomic)
            try FileManager.default.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    private func locateBinary(name: String, candidates: [String]) -> String? {
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let pathEntries =
            (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private func locateFile(candidates: [String]) -> URL? {
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private func locateVirtioISO(resourcesDirectory: URL?) -> URL? {
        var candidates: [URL] = []
        if let resourcesDirectory {
            candidates.append(resourcesDirectory.appendingPathComponent("virtio-win.iso"))
            candidates.append(resourcesDirectory.appendingPathComponent("virtio-drivers.iso"))
            candidates.append(resourcesDirectory.appendingPathComponent("provision/virtio-drivers.iso"))
        }
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/WinRun/virtio-win.iso")
        )
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func waitForSocket(at url: URL, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
