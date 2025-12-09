import ArgumentParser
import Foundation
import Dispatch
import WinRunShared
import WinRunXPC

struct WinRunCLI: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "winrun",
        abstract: "macOS CLI for WinRun Windows virtualization",
        subcommands: [
            Launch.self,
            VM.self,
            Session.self,
            Shortcut.self,
            Config.self,
            CreateLauncher.self,
            Init.self
        ]
    )
}

extension WinRunCLI {
    struct Launch: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Launch a Windows program")

        @Argument(help: "Path to Windows executable")
        var executable: String

        @Argument(parsing: .captureForPassthrough, help: "Arguments passed to executable")
        var args: [String] = []

        mutating func run() throws {
            let executablePath = executable
            let arguments = args
            Task {
                let client = WinRunDaemonClient()
                let request = ProgramLaunchRequest(windowsPath: executablePath, arguments: arguments)
                do {
                    _ = try await client.ensureVMRunning()
                    try await client.executeProgram(request)
                    print("Launched \(executablePath)")
                } catch {
                    WinRunCLI.exit(withError: error)
                }
            }
            dispatchMain()
        }
    }

    struct VM: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Manage the Windows VM")

        @Argument(help: "start | stop | suspend | status")
        var action: String

        mutating func run() throws {
            let actionValue = action
            Task {
                let client = WinRunDaemonClient()
                do {
                    switch actionValue {
                    case "start":
                        let state = try await client.ensureVMRunning()
                        print("VM status: \(state.status.rawValue)")
                    case "stop":
                        let state = try await client.stopVM()
                        print("VM stopped: \(state.status.rawValue)")
                    case "suspend":
                        try await client.suspendIfIdle()
                        print("Requested suspend")
                    case "status":
                        let state = try await client.status()
                        print("Status: \(state.status.rawValue), sessions: \(state.activeSessions)")
                    default:
                        throw WinRunError.notSupported(feature: "vm \(actionValue)")
                    }
                } catch {
                    WinRunCLI.exit(withError: error)
                }
            }
            dispatchMain()
        }
    }

    struct Session: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Manage guest sessions",
            subcommands: [List.self, Close.self],
            defaultSubcommand: List.self
        )

        struct List: ParsableCommand {
            static var configuration = CommandConfiguration(abstract: "List active sessions")

            @Flag(name: .shortAndLong, help: "Output as JSON")
            var json: Bool = false

            mutating func run() throws {
                let jsonOutput = json
                Task {
                    let client = WinRunDaemonClient()
                    do {
                        let result = try await client.listSessions()
                        if jsonOutput {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            encoder.dateEncodingStrategy = .iso8601
                            let data = try encoder.encode(result)
                            print(String(data: data, encoding: .utf8) ?? "{}")
                        } else if result.sessions.isEmpty {
                            print("No active sessions")
                        } else {
                            let formatter = DateFormatter()
                            formatter.dateStyle = .short
                            formatter.timeStyle = .medium
                            for session in result.sessions {
                                let title = session.windowTitle ?? "(no title)"
                                let started = formatter.string(from: session.startedAt)
                                print("\(session.id)  \(title)")
                                print("    Path: \(session.windowsPath)")
                                print("    PID: \(session.processId), Started: \(started)")
                            }
                        }
                    } catch {
                        WinRunCLI.exit(withError: error)
                    }
                }
                dispatchMain()
            }
        }

        struct Close: ParsableCommand {
            static var configuration = CommandConfiguration(abstract: "Close a session by ID")

            @Argument(help: "Session ID to close")
            var sessionId: String

            mutating func run() throws {
                let id = sessionId
                Task {
                    let client = WinRunDaemonClient()
                    do {
                        try await client.closeSession(id)
                        print("Closed session \(id)")
                    } catch {
                        WinRunCLI.exit(withError: error)
                    }
                }
                dispatchMain()
            }
        }
    }

    struct Shortcut: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Manage Windows shortcuts",
            subcommands: [List.self, Sync.self],
            defaultSubcommand: List.self
        )

        struct List: ParsableCommand {
            static var configuration = CommandConfiguration(abstract: "List detected Windows shortcuts")

            @Flag(name: .shortAndLong, help: "Output as JSON")
            var json: Bool = false

            mutating func run() throws {
                let jsonOutput = json
                Task {
                    let client = WinRunDaemonClient()
                    do {
                        let result = try await client.listShortcuts()
                        if jsonOutput {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            encoder.dateEncodingStrategy = .iso8601
                            let data = try encoder.encode(result)
                            print(String(data: data, encoding: .utf8) ?? "{}")
                        } else if result.shortcuts.isEmpty {
                            print("No Windows shortcuts detected")
                            print("Shortcuts will appear here when the guest agent detects them.")
                        } else {
                            for shortcut in result.shortcuts {
                                print("\(shortcut.displayName)")
                                print("    Target: \(shortcut.targetPath)")
                                if let args = shortcut.arguments, !args.isEmpty {
                                    print("    Args: \(args)")
                                }
                            }
                        }
                    } catch {
                        WinRunCLI.exit(withError: error)
                    }
                }
                dispatchMain()
            }
        }

        struct Sync: ParsableCommand {
            static var configuration = CommandConfiguration(
                abstract: "Create macOS launchers for detected Windows shortcuts"
            )

            @Option(name: .shortAndLong, help: "Destination folder (default: ~/Applications/WinRun Apps)")
            var destination: String?

            @Flag(name: .shortAndLong, help: "Output as JSON")
            var json: Bool = false

            mutating func run() throws {
                let destinationRoot = destination
                    ?? FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Applications/WinRun Apps", isDirectory: true).path
                let jsonOutput = json

                Task {
                    let client = WinRunDaemonClient()
                    do {
                        let result = try await client.syncShortcuts(to: destinationRoot)
                        if jsonOutput {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            let data = try encoder.encode(result)
                            print(String(data: data, encoding: .utf8) ?? "{}")
                        } else {
                            print("Sync complete:")
                            print("  Created: \(result.created)")
                            print("  Skipped: \(result.skipped)")
                            print("  Failed: \(result.failed)")
                            if !result.launcherPaths.isEmpty {
                                print("\nCreated launchers:")
                                for path in result.launcherPaths {
                                    print("  \(path)")
                                }
                            }
                        }
                    } catch {
                        WinRunCLI.exit(withError: error)
                    }
                }
                dispatchMain()
            }
        }
    }

    struct Config: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Inspect configuration")

        mutating func run() throws {
            let config = VMConfiguration()
            print("CPU cores: \(config.resources.cpuCount)")
            print("Memory: \(config.resources.memorySizeGB) GB")
            print("Disk image: \(config.diskImagePath.path)")
        }
    }

    struct CreateLauncher: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Generate a macOS .app launcher")

        @Argument(help: "Windows executable path (e.g., C:\\Program Files\\App\\app.exe)")
        var executable: String

        @Option(name: .shortAndLong, help: "Friendly name for the launcher")
        var name: String?

        @Option(name: .shortAndLong, help: "Destination folder (default: ~/Applications/WinRun Apps)")
        var destination: String?

        @Option(name: .shortAndLong, help: "Path to .icns icon file")
        var icon: String?

        @Option(name: .long, help: "Bundle identifier (default: com.winrun.launcher.<name>)")
        var bundleId: String?

        @Flag(name: .long, help: "Overwrite existing launcher if present")
        var force: Bool = false

        mutating func run() throws {
            let destinationRoot = destination.map(URL.init(fileURLWithPath:))
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/WinRun Apps", isDirectory: true)

            let launcher = LauncherBuilder(destinationRoot: destinationRoot)
            let config = LauncherConfiguration(
                windowsPath: executable,
                displayName: name,
                iconPath: icon.map(URL.init(fileURLWithPath:)),
                bundleIdentifier: bundleId,
                overwrite: force
            )

            let bundlePath = try launcher.generate(config: config)
            print("Created launcher: \(bundlePath.path)")
        }
    }

    struct Init: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Bootstrap the WinRun environment")

        mutating func run() throws {
            print("Downloading Windows image (mock)...")
            sleep(1)
            print("Installing guest tools (mock)...")
            sleep(1)
            print("WinRun initialized.")
        }
    }
}

struct LauncherConfiguration {
    let windowsPath: String
    let displayName: String?
    let iconPath: URL?
    let bundleIdentifier: String?
    let overwrite: Bool

    var resolvedName: String {
        displayName ?? URL(fileURLWithPath: windowsPath).deletingPathExtension().lastPathComponent
    }

    var resolvedBundleIdentifier: String {
        bundleIdentifier ?? "com.winrun.launcher.\(sanitizedName)"
    }

    private var sanitizedName: String {
        resolvedName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }
}

enum LauncherBuilderError: Error, CustomStringConvertible {
    case bundleAlreadyExists(URL)
    case iconNotFound(URL)
    case iconCopyFailed(URL, Error)

    var description: String {
        switch self {
        case .bundleAlreadyExists(let url):
            return "Launcher already exists at \(url.path). Use --force to overwrite."
        case .iconNotFound(let url):
            return "Icon file not found: \(url.path)"
        case .iconCopyFailed(let url, let error):
            return "Failed to copy icon from \(url.path): \(error.localizedDescription)"
        }
    }
}

struct LauncherBuilder {
    let destinationRoot: URL
    private let fm = FileManager.default

    @discardableResult
    func generate(config: LauncherConfiguration) throws -> URL {
        let bundle = destinationRoot.appendingPathComponent("\(config.resolvedName).app", isDirectory: true)

        // Check if bundle exists
        if fm.fileExists(atPath: bundle.path) {
            if config.overwrite {
                try fm.removeItem(at: bundle)
            } else {
                throw LauncherBuilderError.bundleAlreadyExists(bundle)
            }
        }

        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // Create launcher script
        try writeLauncherScript(to: macOS, windowsPath: config.windowsPath)

        // Copy icon if provided
        var iconFileName: String?
        if let iconPath = config.iconPath {
            iconFileName = try copyIcon(from: iconPath, to: resources)
        }

        // Create Info.plist
        try writeInfoPlist(to: contents, config: config, iconFileName: iconFileName)

        return bundle
    }

    private func writeLauncherScript(to macOSDir: URL, windowsPath: String) throws {
        let launcherPath = macOSDir.appendingPathComponent("launcher")
        // Escape quotes in the Windows path for bash
        let escapedPath = windowsPath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            #!/bin/bash
            # WinRun launcher - Generated by winrun create-launcher
            exec open -n /Applications/WinRun.app --args "\(escapedPath)" "$@"

            """
        try script.write(to: launcherPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath.path)
    }

    private func copyIcon(from source: URL, to resourcesDir: URL) throws -> String {
        guard fm.fileExists(atPath: source.path) else {
            throw LauncherBuilderError.iconNotFound(source)
        }

        let iconFileName = "AppIcon.icns"
        let destination = resourcesDir.appendingPathComponent(iconFileName)

        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw LauncherBuilderError.iconCopyFailed(source, error)
        }

        return iconFileName
    }

    private func writeInfoPlist(to contentsDir: URL, config: LauncherConfiguration, iconFileName: String?) throws {
        var plistEntries = [
            ("CFBundleName", config.resolvedName),
            ("CFBundleDisplayName", config.resolvedName),
            ("CFBundleIdentifier", config.resolvedBundleIdentifier),
            ("CFBundleVersion", "1.0"),
            ("CFBundleShortVersionString", "1.0"),
            ("CFBundleExecutable", "launcher"),
            ("CFBundlePackageType", "APPL"),
            ("CFBundleInfoDictionaryVersion", "6.0"),
            ("LSMinimumSystemVersion", "13.0"),
            ("NSHighResolutionCapable", "true"),
        ]

        if let icon = iconFileName {
            plistEntries.append(("CFBundleIconFile", icon))
        }

        let entriesXml = plistEntries.map { key, value in
            "    <key>\(escapeXml(key))</key>\n    <string>\(escapeXml(value))</string>"
        }.joined(separator: "\n")

        let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \(entriesXml)
            </dict>
            </plist>

            """

        try infoPlist.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }

    private func escapeXml(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

WinRunCLI.main()
