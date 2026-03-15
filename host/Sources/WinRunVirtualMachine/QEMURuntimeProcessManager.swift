import Foundation
import WinRunShared
#if canImport(Darwin)
import Darwin
#endif

enum QEMURuntimeProcessError: LocalizedError {
    case unsupportedNetworkMode(String)
    case spiceNotSupported
    case processExitedEarly
    case spiceStartupTimeout
    case missingProcess

    var errorDescription: String? {
        switch self {
        case .unsupportedNetworkMode(let mode):
            return "QEMU runtime currently supports NAT only (requested: \(mode))."
        case .spiceNotSupported:
            return "The detected qemu-system-aarch64 build does not support SPICE (-spice). "
                + "Use a packaged WinRun app with bundled SPICE-enabled QEMU, install a SPICE-enabled QEMU build, "
                + "or set WINRUN_QEMU_BINARY/WINRUN_QEMU_PREFIX to one."
        case .processExitedEarly:
            return "QEMU exited before the SPICE transport became ready."
        case .spiceStartupTimeout:
            return "Timed out waiting for QEMU SPICE transport to become ready."
        case .missingProcess:
            return "QEMU process was not initialized."
        }
    }
}

final class QEMURuntimeProcessManager {
    private let logger: Logger
    private let spicePort: UInt16
    private var qemuProcess: Process?
    private var swtpmProcess: Process?
    private var qemuStderrPipe: Pipe?
    private var swtpmStderrPipe: Pipe?

    init(
        logger: Logger,
        spicePort: UInt16 = UInt16(ProcessInfo.processInfo.environment["WINRUN_SPICE_PORT"] ?? "5930") ?? 5930
    ) {
        self.logger = logger
        self.spicePort = spicePort
    }

    var isRunning: Bool {
        qemuProcess?.isRunning ?? false
    }

    func start(configuration: VMConfiguration) async throws {
        if isRunning {
            logger.debug("QEMU runtime already running; skipping start")
            return
        }
        guard configuration.network.mode == .nat else {
            throw QEMURuntimeProcessError.unsupportedNetworkMode(configuration.network.mode.rawValue)
        }

        let tools = try QEMUToolResolver.discover()
        logger.info("Resolved QEMU tools for runtime startup")
        logger.debug("qemu=\(tools.qemuBinary.path)")
        logger.debug("swtpm=\(tools.swtpmBinary.path)")
        logger.debug("firmwareCode=\(tools.firmwareCode.path)")
        logger.debug("firmwareVarsTemplate=\(tools.firmwareVarsTemplate.path)")
        guard Self.qemuSupportsSpice(binary: tools.qemuBinary) else {
            throw QEMURuntimeProcessError.spiceNotSupported
        }
        let diskPath = configuration.diskImagePath
        let nvramPath = try QEMUToolResolver.ensureEFIVariableStore(
            diskImagePath: diskPath,
            varsTemplate: tools.firmwareVarsTemplate
        )
        logger.debug("diskImage=\(diskPath.path)")
        logger.debug("nvram=\(nvramPath.path)")

        let tpmStateDir = diskPath.deletingLastPathComponent().appendingPathComponent("swtpm-state")
        let tpmSocket = tpmStateDir.appendingPathComponent("swtpm-sock")

        do {
            swtpmProcess = try launchSwtpm(binary: tools.swtpmBinary, stateDir: tpmStateDir, socketPath: tpmSocket)

            let args = Self.buildArguments(
                configuration: configuration,
                firmwareCode: tools.firmwareCode,
                nvram: nvramPath,
                tpmSocketPath: tpmSocket,
                spicePort: spicePort
            )
            logger.debug("QEMU arguments: \(args.joined(separator: " "))")

            let stderrPipe = Pipe()
            qemuStderrPipe = stderrPipe
            let process = Process()
            process.executableURL = tools.qemuBinary
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderrPipe
            process.terminationHandler = { [weak self] terminated in
                self?.logger.error(
                    "QEMU process terminated pid=\(terminated.processIdentifier) status=\(terminated.terminationStatus)"
                )
            }
            try process.run()
            qemuProcess = process
            logger.info("QEMU process started pid=\(process.processIdentifier)")

            Task.detached { [weak self] in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
                self?.logger.debug("QEMU stderr:\n\(output)")
            }

            try await waitForSpiceReady(timeoutSeconds: 25)
        } catch {
            logger.error("Runtime start failed; cleaning up partial processes: \(error.localizedDescription)")
            await stopProcess(qemuProcess, graceSeconds: 2)
            await stopProcess(swtpmProcess, graceSeconds: 2)
            qemuProcess = nil
            swtpmProcess = nil
            qemuStderrPipe = nil
            swtpmStderrPipe = nil
            throw error
        }
    }

    func stop() async {
        await stopProcess(qemuProcess, graceSeconds: 8)
        await stopProcess(swtpmProcess, graceSeconds: 3)
        qemuProcess = nil
        swtpmProcess = nil
        qemuStderrPipe = nil
        swtpmStderrPipe = nil
    }

    func checkHealth() throws {
        if let process = qemuProcess, !process.isRunning {
            throw QEMURuntimeProcessError.processExitedEarly
        }
    }

    static func buildArguments(
        configuration: VMConfiguration,
        firmwareCode: URL,
        nvram: URL,
        tpmSocketPath: URL,
        spicePort: UInt16
    ) -> [String] {
        let memoryMB = max(4096, configuration.resources.memorySizeGB * 1024)
        let cpuCount = max(2, configuration.resources.cpuCount)
        let mac = configuration.network.macAddress ?? "52:54:00:12:34:56"

        return [
            "-M", "virt,highmem=on",
            "-cpu", "host",
            "-accel", "hvf",
            "-m", "\(memoryMB)",
            "-smp", "\(cpuCount)",
            "-drive", "if=pflash,format=raw,file=\(firmwareCode.path),readonly=on",
            "-drive", "if=pflash,format=raw,file=\(nvram.path)",
            // Keep headless local rendering and expose display via SPICE server.
            "-display", "none",
            // Use boot framebuffer + virtio GPU for ongoing desktop updates.
            "-device", "ramfb",
            "-device", "virtio-gpu-pci",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
            "-drive", "file=\(configuration.diskImagePath.path),if=virtio,format=raw,discard=on",
            "-spice", "addr=127.0.0.1,port=\(spicePort),disable-ticketing=on,agent-mouse=on",
            "-device", "virtio-serial",
            "-chardev", "spicevmc,id=vdagent,name=vdagent",
            "-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0",
            "-chardev", "socket,id=chrtpm,path=\(tpmSocketPath.path)",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
            "-device", "tpm-tis-device,tpmdev=tpm0",
            "-nic", "user,model=virtio-net-pci,mac=\(mac)",
        ]
    }

    private func waitForSpiceReady(timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            if let process = qemuProcess, !process.isRunning {
                throw QEMURuntimeProcessError.processExitedEarly
            }
            if canConnectToLocalPort(spicePort) {
                logger.info("QEMU SPICE transport is ready on 127.0.0.1:\(spicePort)")
                return
            }
            if attempt <= 5 || attempt % 10 == 0 {
                logger.debug("Waiting for SPICE port 127.0.0.1:\(spicePort) (attempt \(attempt))")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw QEMURuntimeProcessError.spiceStartupTimeout
    }

    private func launchSwtpm(binary: URL, stateDir: URL, socketPath: URL) throws -> Process? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: stateDir.path) {
            try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        }
        let lockPath = stateDir.appendingPathComponent(".lock")

        // If a TPM emulator is already serving this socket (e.g. from a prior app
        // instance), reuse it instead of tearing it down. Unlinking an active UNIX
        // socket path can leave the existing daemon unreachable and cause QEMU TPM
        // initialization to fail.
        if canConnectToUnixSocket(socketPath.path) {
            logger.info("Reusing existing swtpm instance at \(socketPath.path)")
            return nil
        }

        // If no socket is reachable but a lock file exists, we likely have stale
        // lock state from a previously interrupted launch. Remove it so a fresh
        // swtpm can initialize.
        if fm.fileExists(atPath: lockPath.path) {
            logger.warn("swtpm lock exists but socket is unreachable; clearing stale lock at \(lockPath.path)")
            try? fm.removeItem(at: lockPath)
        }

        // Remove stale socket file only when no process is serving it.
        if fm.fileExists(atPath: socketPath.path) {
            try? fm.removeItem(at: socketPath)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "socket",
            "--tpmstate", "dir=\(stateDir.path)",
            "--ctrl", "type=unixio,path=\(socketPath.path)",
            "--tpm2",
        ]
        let stderrPipe = Pipe()
        swtpmStderrPipe = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] terminated in
            self?.logger.error(
                "swtpm process terminated pid=\(terminated.processIdentifier) status=\(terminated.terminationStatus)"
            )
        }
        try process.run()
        logger.info("swtpm process started pid=\(process.processIdentifier)")
        Task.detached { [weak self] in
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.logger.debug("swtpm stderr:\n\(output)")
        }
        Thread.sleep(forTimeInterval: 0.4)
        return process
    }

    private func canConnectToUnixSocket(_ path: String) -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { _ = Darwin.close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        let utf8 = Array(path.utf8.prefix(maxPathLength))
        guard !utf8.isEmpty else { return false }

        withUnsafeMutablePointer(to: &address.sun_path.0) { ptr in
            utf8.withUnsafeBufferPointer { bytes in
                for i in 0..<bytes.count {
                    ptr.advanced(by: i).pointee = Int8(bitPattern: bytes[i])
                }
                ptr.advanced(by: bytes.count).pointee = 0
            }
        }

        let length = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, length)
            }
        }
        return result == 0
        #else
        return false
        #endif
    }

    private func stopProcess(_ process: Process?, graceSeconds: TimeInterval) async {
        guard let process else { return }
        guard process.isRunning else { return }
        logger.info("Stopping process pid=\(process.processIdentifier) grace=\(graceSeconds)s")

        #if canImport(Darwin)
        _ = kill(process.processIdentifier, SIGTERM)
        #endif

        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if !process.isRunning {
                logger.info("Process pid=\(process.processIdentifier) exited gracefully")
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        #if canImport(Darwin)
        logger.warn("Process pid=\(process.processIdentifier) did not exit in time; sending SIGKILL")
        _ = kill(process.processIdentifier, SIGKILL)
        #endif
    }

    private func canConnectToLocalPort(_ port: UInt16) -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { _ = Darwin.close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = CFSwapInt16HostToBig(port)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
        #else
        return false
        #endif
    }

    private static func qemuSupportsSpice(binary: URL) -> Bool {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-spice"]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        return !stderr.contains("invalid option")
    }
}
