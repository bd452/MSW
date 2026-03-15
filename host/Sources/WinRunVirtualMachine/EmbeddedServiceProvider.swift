import Foundation
import WinRunShared
import WinRunSpiceBridge

/// Runs VM management in-process without a separate daemon.
///
/// Used in debug/development builds so the app doesn't need to install
/// a LaunchDaemon. The VM lifecycle is tied to the app process.
public final class EmbeddedServiceProvider: VMServiceProvider {
    private let vmController: VirtualMachineController
    private let controlChannel: SpiceControlChannel
    private let logger: Logger

    public init(
        configuration: VMConfiguration = VMConfiguration(),
        logger: Logger = StandardLogger(subsystem: "EmbeddedVM"),
        controlChannel: SpiceControlChannel? = nil
    ) {
        self.vmController = VirtualMachineController(
            configuration: configuration, logger: logger)
        self.logger = logger
        self.controlChannel = controlChannel ?? SpiceControlChannel(logger: logger)
    }

    public func ensureVMRunning() async throws -> VMState {
        logger.debug("Ensuring VM is running (embedded)")
        return try await vmController.ensureRunning()
    }

    public func executeProgram(_ request: ProgramLaunchRequest) async throws {
        _ = try await vmController.ensureRunning()
        try await ensureControlChannel()
        try await controlChannel.launchProgram(request)
        logger.info("Launched \(request.windowsPath)")
        await vmController.registerSession(delta: 1)
    }

    public func status() async throws -> VMState {
        await vmController.currentState()
    }

    public func suspendIfIdle() async throws {
        try await vmController.suspendIfIdle()
    }

    public func stopVM() async throws -> VMState {
        try await vmController.shutdown()
    }

    public func listSessions() async throws -> GuestSessionList {
        let state = await vmController.currentState()
        guard state.status == .running else {
            return GuestSessionList(sessions: [])
        }
        do {
            try await ensureControlChannel()
            return try await controlChannel.listSessions()
        } catch {
            logger.warn("Failed to list sessions: \(error)")
            return GuestSessionList(sessions: [])
        }
    }

    public func closeSession(_ sessionId: String) async throws {
        let state = await vmController.currentState()
        guard state.status == .running else { return }
        try await ensureControlChannel()
        try await controlChannel.closeSession(sessionId)
    }

    public func listShortcuts() async throws -> WindowsShortcutList {
        let state = await vmController.currentState()
        guard state.status == .running else {
            return WindowsShortcutList(shortcuts: [])
        }
        do {
            try await ensureControlChannel()
            return try await controlChannel.listShortcuts()
        } catch {
            logger.warn("Failed to list shortcuts: \(error)")
            return WindowsShortcutList(shortcuts: [])
        }
    }

    public func syncShortcuts(
        to destinationPath: String
    ) async throws -> ShortcutSyncResult {
        let state = await vmController.currentState()
        guard state.status == .running else {
            return ShortcutSyncResult(
                created: 0, skipped: 0, failed: 0, launcherPaths: [])
        }
        do {
            try await ensureControlChannel()
            let shortcuts = try await controlChannel.listShortcuts()
            return buildLaunchers(
                shortcuts.shortcuts,
                destination: URL(fileURLWithPath: destinationPath, isDirectory: true)
            )
        } catch {
            logger.warn("Failed to sync shortcuts: \(error)")
            return ShortcutSyncResult(
                created: 0, skipped: 0, failed: 0, launcherPaths: [])
        }
    }

    /// Attempts to reach the guest agent via the control channel.
    /// Throws if the agent is unreachable (unlike `listSessions` which swallows errors).
    public func pingAgent() async throws {
        try await ensureControlChannel()
        _ = try await controlChannel.listSessions(timeout: .seconds(3))
    }

    // MARK: - Private

    private func ensureControlChannel() async throws {
        if await !controlChannel.connected {
            try await controlChannel.connect()
        }
    }

    private func buildLaunchers(
        _ shortcuts: [WindowsShortcut],
        destination: URL
    ) -> ShortcutSyncResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var created = 0
        var skipped = 0
        var failed = 0
        var paths: [String] = []
        let destPrefix = destination.standardizedFileURL.path

        for shortcut in shortcuts {
            let name = shortcut.displayName
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)

            guard !name.isEmpty else {
                failed += 1
                continue
            }

            let bundlePath = destination.appendingPathComponent(
                "\(name).app", isDirectory: true)

            guard bundlePath.standardizedFileURL.path.hasPrefix(destPrefix) else {
                failed += 1
                continue
            }

            if fm.fileExists(atPath: bundlePath.path) {
                skipped += 1
                continue
            }

            do {
                try createMinimalLauncher(
                    at: bundlePath, windowsPath: shortcut.targetPath, name: name)
                paths.append(bundlePath.path)
                created += 1
            } catch {
                logger.error("Failed to create launcher for \(name): \(error)")
                failed += 1
            }
        }

        return ShortcutSyncResult(
            created: created,
            skipped: skipped,
            failed: failed,
            launcherPaths: paths
        )
    }

    private func createMinimalLauncher(
        at bundleURL: URL, windowsPath: String, name: String
    ) throws {
        let macOS = bundleURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(
            at: macOS, withIntermediateDirectories: true)

        let escapedPath = windowsPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
            #!/bin/bash
            open -n /Applications/WinRun.app --args '\(escapedPath)'
            """
        let scriptURL = macOS.appendingPathComponent("launcher")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
}
