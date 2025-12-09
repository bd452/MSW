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
                    case "suspend":
                        try await client.suspendIfIdle()
                        print("Requested suspend")
                    case "status":
                        let state = try await client.status()
                        print("Status: \(state.status.rawValue), sessions: \(state.activeSessions)")
                    default:
                        throw WinRunError.launchFailed(reason: "Unsupported action \(actionValue)")
                    }
                } catch {
                    WinRunCLI.exit(withError: error)
                }
            }
            dispatchMain()
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

        @Argument var executable: String
        @Option(name: .shortAndLong, help: "Friendly name") var name: String?
        @Option(name: .shortAndLong, help: "Destination folder") var destination: String?

        mutating func run() throws {
            let launcher = LauncherBuilder(
                destinationRoot: destination.map(URL.init(fileURLWithPath:)) ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/WinRun Apps", isDirectory: true)
            )
            try launcher.generate(for: executable, displayName: name)
            print("Created launcher for \(executable)")
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

struct LauncherBuilder {
    let destinationRoot: URL

    func generate(for windowsPath: String, displayName: String?) throws {
        let name = displayName ?? URL(fileURLWithPath: windowsPath).deletingPathExtension().lastPathComponent
        let bundle = destinationRoot.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let launcherPath = macOS.appendingPathComponent("launcher")
        let script = "#!/bin/bash\nopen -n /Applications/WinRun.app --args \"\(windowsPath)\"\n"
        try script.write(to: launcherPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath.path)
        let infoPlist = """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <!DOCTYPE plist PUBLIC \"-//Apple Computer//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
        <plist version=\"1.0\">
        <dict>
            <key>CFBundleName</key>
            <string>\(name)</string>
            <key>CFBundleExecutable</key>
            <string>launcher</string>
        </dict>
        </plist>
        """
        try infoPlist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }
}

WinRunCLI.main()
