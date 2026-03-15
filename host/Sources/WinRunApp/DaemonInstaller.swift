import Foundation
import WinRunShared

/// Checks whether the WinRun daemon is installed and running, and installs it
/// with admin privileges if needed.
@available(macOS 13, *)
enum DaemonInstaller {
    private static let daemonLabel = "com.winrun.daemon"
    private static let plistDestination = "/Library/LaunchDaemons/com.winrun.daemon.plist"
    private static let binaryDestination = "/usr/local/bin/winrund"

    enum InstallResult {
        case alreadyRunning
        case installed
        case failed(String)
        case userCancelled
    }

    static func isDaemonRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(daemonLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func ensureDaemonInstalled(logger: Logger) -> InstallResult {
        if isDaemonRunning() {
            logger.info("Daemon already running")
            return .alreadyRunning
        }

        guard let binaryPath = findDaemonBinary() else {
            return .failed(
                "Could not find winrund binary. Build with 'make build-host' first.")
        }

        guard let plistPath = findPlistSource() else {
            return .failed(
                "Could not find daemon plist at infrastructure/launchd/com.winrun.daemon.plist")
        }

        logger.info("Installing daemon from \(binaryPath.path)")

        let script = buildInstallScript(
            binarySource: binaryPath.path,
            plistSource: plistPath.path
        )

        return runWithAdminPrivileges(script: script, logger: logger)
    }

    private static func findDaemonBinary() -> URL? {
        // 1. Inside the running app bundle
        if let bundlePath = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("winrund"),
            FileManager.default.fileExists(atPath: bundlePath.path) {
            return bundlePath
        }

        // 2. Release build in the source tree
        let repoRoot = findRepoRoot()
        if let root = repoRoot {
            let release = root
                .appendingPathComponent("host/.build/release/winrund")
            if FileManager.default.fileExists(atPath: release.path) {
                return release
            }
            let debug = root
                .appendingPathComponent("host/.build/debug/winrund")
            if FileManager.default.fileExists(atPath: debug.path) {
                return debug
            }
        }

        return nil
    }

    private static func findPlistSource() -> URL? {
        // 1. Inside the app bundle Resources
        if let bundled = Bundle.main.url(
            forResource: "com.winrun.daemon", withExtension: "plist") {
            return bundled
        }

        // 2. In the source tree
        if let root = findRepoRoot() {
            let plist = root
                .appendingPathComponent(
                    "infrastructure/launchd/com.winrun.daemon.plist")
            if FileManager.default.fileExists(atPath: plist.path) {
                return plist
            }
        }

        return nil
    }

    private static func findRepoRoot() -> URL? {
        // Walk up from the main bundle or current directory looking for Makefile
        var candidate = Bundle.main.bundleURL
        for _ in 0..<6 {
            candidate = candidate.deletingLastPathComponent()
            let makefile = candidate.appendingPathComponent("Makefile")
            if FileManager.default.fileExists(atPath: makefile.path) {
                return candidate
            }
        }

        // Try from current working directory
        var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let makefile = cwd.appendingPathComponent("Makefile")
            if FileManager.default.fileExists(atPath: makefile.path) {
                return cwd
            }
            cwd = cwd.deletingLastPathComponent()
        }

        return nil
    }

    private static func buildInstallScript(
        binarySource: String,
        plistSource: String
    ) -> String {
        // Shell script that installs the daemon with proper permissions.
        // Unloads any existing daemon first to handle upgrades cleanly.
        """
        #!/bin/bash
        set -euo pipefail
        LABEL="\(daemonLabel)"
        PLIST_DST="\(plistDestination)"
        BIN_DST="\(binaryDestination)"

        # Unload if already loaded
        launchctl print "system/${LABEL}" &>/dev/null && \
            launchctl bootout "system/${LABEL}" 2>/dev/null || true
        sleep 1

        # Install binary
        mkdir -p "$(dirname "${BIN_DST}")"
        cp "\(binarySource)" "${BIN_DST}"
        chown root:wheel "${BIN_DST}"
        chmod 755 "${BIN_DST}"

        # Install plist
        cp "\(plistSource)" "${PLIST_DST}"
        chown root:wheel "${PLIST_DST}"
        chmod 644 "${PLIST_DST}"

        # Load
        launchctl bootstrap system "${PLIST_DST}"
        """
    }

    private static func runWithAdminPrivileges(
        script: String, logger: Logger
    ) -> InstallResult {
        let tempScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("winrun-install-daemon.sh")

        do {
            try script.write(to: tempScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tempScript.path)
        } catch {
            return .failed("Failed to write install script: \(error.localizedDescription)")
        }

        defer {
            try? FileManager.default.removeItem(at: tempScript)
        }

        // Use osascript to request admin privileges via the system auth dialog
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = [
            "-e",
            """
            do shell script "\(tempScript.path)" with administrator privileges
            """,
        ]

        let errPipe = Pipe()
        osa.standardError = errPipe

        do {
            try osa.run()
            osa.waitUntilExit()
        } catch {
            return .failed("Failed to launch admin prompt: \(error.localizedDescription)")
        }

        if osa.terminationStatus == 0 {
            logger.info("Daemon installed successfully")
            return .installed
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errMsg = String(data: errData, encoding: .utf8) ?? ""

        if errMsg.contains("User canceled") || errMsg.contains("-128") {
            logger.info("User cancelled daemon installation")
            return .userCancelled
        }

        return .failed("Install script failed (exit \(osa.terminationStatus)): \(errMsg)")
    }
}
