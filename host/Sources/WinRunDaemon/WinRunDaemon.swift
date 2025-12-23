import Foundation
import WinRunShared
import WinRunVirtualMachine
import WinRunXPC
import WinRunSpiceBridge
import Security

@objc final class WinRunDaemonService: NSObject, WinRunDaemonXPC {
    private let vmController: VirtualMachineController
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rateLimiter: RateLimiter
    private let controlChannel: SpiceControlChannel

    /// Client identifier for the current request (set by connection handler)
    var currentClientId: String?

    init(
        configuration: VMConfiguration = VMConfiguration(),
        logger: Logger = StandardLogger(subsystem: "winrund"),
        throttlingConfig: ThrottlingConfig = .production,
        controlChannel: SpiceControlChannel? = nil
    ) {
        self.vmController = VirtualMachineController(configuration: configuration, logger: logger)
        self.logger = logger
        self.rateLimiter = RateLimiter(config: throttlingConfig, logger: logger)
        self.controlChannel = controlChannel ?? SpiceControlChannel(logger: logger)
    }

    /// Check rate limit before processing request
    private func checkThrottle() async throws {
        guard let clientId = currentClientId else { return }
        let result = await rateLimiter.checkRequest(clientId: clientId)
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Prune stale rate limit entries
    func pruneStaleClients() async {
        await rateLimiter.pruneStaleClients()
        logger.debug("Pruned stale rate limit entries")
    }

    func ensureVMRunning(_ reply: @escaping (NSData?, NSError?) -> Void) {
        Task { [self] in
            do {
                try await checkThrottle()
                let state = try await vmController.ensureRunning()
                reply(try encode(state), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    func executeProgram(_ requestData: NSData, reply: @escaping (NSError?) -> Void) {
        let data = Data(referencing: requestData)
        Task { [self] in
            do {
                try await checkThrottle()
                let request = try decode(ProgramLaunchRequest.self, from: data)
                _ = try await vmController.ensureRunning()
                logger.info("Would launch \(request.windowsPath) with args \(request.arguments)")
                await vmController.registerSession(delta: 1)
                reply(nil)
            } catch {
                reply(nsError(error))
            }
        }
    }

    func getStatus(_ reply: @escaping (NSData?, NSError?) -> Void) {
        Task { [self] in
            do {
                try await checkThrottle()
                let status = await vmController.currentState()
                reply(try encode(status), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    func suspendIfIdle(_ reply: @escaping (NSError?) -> Void) {
        Task { [self] in
            do {
                try await checkThrottle()
                try await vmController.suspendIfIdle()
                reply(nil)
            } catch {
                reply(nsError(error))
            }
        }
    }

    func stopVM(_ reply: @escaping (NSData?, NSError?) -> Void) {
        Task { [self] in
            do {
                try await checkThrottle()
                let state = try await vmController.shutdown()
                reply(try encode(state), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    // MARK: - Session Management

    func listSessions(_ reply: @escaping (NSData?, NSError?) -> Void) {
        Task { [self] in
            do {
                try await checkThrottle()

                // Query guest agent for actual sessions
                let vmState = await vmController.currentState()
                guard vmState.status == .running else {
                    // VM not running, return empty list
                    let sessions = GuestSessionList(sessions: [])
                    reply(try encode(sessions), nil)
                    return
                }

                // Ensure control channel is connected
                if await !controlChannel.connected {
                    try await controlChannel.connect()
                }

                // Request sessions from guest
                let sessions = try await controlChannel.listSessions()
                logger.info("Retrieved \(sessions.sessions.count) sessions from guest")
                reply(try encode(sessions), nil)
            } catch let error as SpiceControlError {
                // For control errors, return empty list with warning
                logger.warn("Failed to list sessions: \(error.description)")
                let sessions = GuestSessionList(sessions: [])
                reply(try encode(sessions), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    func closeSession(_ sessionId: NSString, reply: @escaping (NSError?) -> Void) {
        let id = sessionId as String
        Task { [self] in
            do {
                try await checkThrottle()

                // Check VM state
                let vmState = await vmController.currentState()
                guard vmState.status == .running else {
                    logger.warn("Cannot close session - VM not running")
                    reply(nil)
                    return
                }

                // Ensure control channel is connected
                if await !controlChannel.connected {
                    try await controlChannel.connect()
                }

                // Send close session command to guest
                try await controlChannel.closeSession(id)
                logger.info("Closed session \(id)")
                reply(nil)
            } catch let error as SpiceControlError {
                logger.error("Failed to close session \(id): \(error.description)")
                reply(nsError(error))
            } catch {
                reply(nsError(error))
            }
        }
    }

    // MARK: - Shortcut Management

    func listShortcuts(_ reply: @escaping (NSData?, NSError?) -> Void) {
        Task { [self] in
            do {
                try await checkThrottle()

                // Query guest agent for detected shortcuts
                let vmState = await vmController.currentState()
                guard vmState.status == .running else {
                    // VM not running, return empty list
                    let shortcuts = WindowsShortcutList(shortcuts: [])
                    reply(try encode(shortcuts), nil)
                    return
                }

                // Ensure control channel is connected
                if await !controlChannel.connected {
                    try await controlChannel.connect()
                }

                // Request shortcuts from guest
                let shortcuts = try await controlChannel.listShortcuts()
                logger.info("Retrieved \(shortcuts.shortcuts.count) shortcuts from guest")
                reply(try encode(shortcuts), nil)
            } catch let error as SpiceControlError {
                // For control errors, return empty list with warning
                logger.warn("Failed to list shortcuts: \(error.description)")
                let shortcuts = WindowsShortcutList(shortcuts: [])
                reply(try encode(shortcuts), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    func syncShortcuts(_ destinationPath: NSString, reply: @escaping (NSData?, NSError?) -> Void) {
        let destinationRoot = URL(fileURLWithPath: destinationPath as String, isDirectory: true)
        Task { [self] in
            do {
                try await checkThrottle()

                // Get shortcuts from guest
                let vmState = await vmController.currentState()
                guard vmState.status == .running else {
                    logger.warn("Cannot sync shortcuts - VM not running")
                    let result = ShortcutSyncResult(created: 0, skipped: 0, failed: 0, launcherPaths: [])
                    reply(try encode(result), nil)
                    return
                }

                // Ensure control channel is connected
                if await !controlChannel.connected {
                    try await controlChannel.connect()
                }

                // Request shortcuts from guest
                let shortcuts = try await controlChannel.listShortcuts()
                logger.info("Syncing \(shortcuts.shortcuts.count) shortcuts to \(destinationRoot.path)")

                // Create destination directory if needed
                let fm = FileManager.default
                try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

                var created = 0
                var skipped = 0
                var failed = 0
                var launcherPaths: [String] = []

                for shortcut in shortcuts.shortcuts {
                    let bundlePath = destinationRoot.appendingPathComponent("\(shortcut.displayName).app", isDirectory: true)

                    // Skip if already exists
                    if fm.fileExists(atPath: bundlePath.path) {
                        logger.debug("Skipping existing launcher: \(shortcut.displayName)")
                        skipped += 1
                        continue
                    }

                    do {
                        try createLauncherBundle(
                            at: bundlePath,
                            windowsPath: shortcut.targetPath,
                            displayName: shortcut.displayName,
                            arguments: shortcut.arguments
                        )
                        launcherPaths.append(bundlePath.path)
                        created += 1
                        logger.info("Created launcher: \(shortcut.displayName)")
                    } catch {
                        logger.error("Failed to create launcher for \(shortcut.displayName): \(error)")
                        failed += 1
                    }
                }

                let result = ShortcutSyncResult(
                    created: created,
                    skipped: skipped,
                    failed: failed,
                    launcherPaths: launcherPaths
                )
                reply(try encode(result), nil)
            } catch let error as SpiceControlError {
                logger.error("Failed to sync shortcuts: \(error.description)")
                let result = ShortcutSyncResult(created: 0, skipped: 0, failed: 0, launcherPaths: [])
                reply(try encode(result), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    /// Creates a minimal macOS .app launcher bundle for a Windows executable.
    private func createLauncherBundle(
        at bundleURL: URL,
        windowsPath: String,
        displayName: String,
        arguments: String?
    ) throws {
        let fm = FileManager.default
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // Create launcher script
        let launcherPath = macOS.appendingPathComponent("launcher")
        let escapedPath = windowsPath.replacingOccurrences(of: "\"", with: "\\\"")
        var script = """
            #!/bin/bash
            # WinRun launcher - Generated by winrund shortcut sync
            exec open -n /Applications/WinRun.app --args "\(escapedPath)"
            """
        if let args = arguments, !args.isEmpty {
            script += " \(args)"
        }
        script += " \"$@\"\n"

        try script.write(to: launcherPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath.path)

        // Create Info.plist
        let sanitizedName = displayName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        let bundleId = "com.winrun.launcher.\(sanitizedName)"

        let infoPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleName</key>
                <string>\(escapeXml(displayName))</string>
                <key>CFBundleDisplayName</key>
                <string>\(escapeXml(displayName))</string>
                <key>CFBundleIdentifier</key>
                <string>\(escapeXml(bundleId))</string>
                <key>CFBundleVersion</key>
                <string>1.0</string>
                <key>CFBundleShortVersionString</key>
                <string>1.0</string>
                <key>CFBundleExecutable</key>
                <string>launcher</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>CFBundleInfoDictionaryVersion</key>
                <string>6.0</string>
                <key>LSMinimumSystemVersion</key>
                <string>13.0</string>
                <key>NSHighResolutionCapable</key>
                <true/>
            </dict>
            </plist>

            """

        try infoPlist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func escapeXml(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func encode<T: Encodable>(_ value: T) throws -> NSData {
        try NSData(data: encoder.encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    private func nsError(_ error: Error) -> NSError {
        if let nsError = error as NSError? {
            return nsError
        }
        return NSError(domain: "com.winrun.daemon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: error.localizedDescription
        ])
    }
}

@main
struct WinRunDaemonMain {
    static func main() {
        let logger = StandardLogger(subsystem: "winrund-main")
        logger.info("Starting winrund XPC service")

        // Configure authentication and throttling
        // Use development config for now; production would load from config file
        #if DEBUG
        let authConfig = XPCAuthenticationConfig.development
        let throttlingConfig = ThrottlingConfig.development
        #else
        let authConfig = XPCAuthenticationConfig.production
        let throttlingConfig = ThrottlingConfig.production
        #endif

        logger.info("Auth config: allowUnsigned=\(authConfig.allowUnsignedClients), group=\(authConfig.allowedGroupName ?? "none")")
        logger.info("Throttling config: \(throttlingConfig.maxRequestsPerWindow) req/\(Int(throttlingConfig.windowSeconds))s")

        let service = WinRunDaemonService(logger: logger, throttlingConfig: throttlingConfig)
        let listenerDelegate = WinRunDaemonListener(service: service, logger: logger, authConfig: authConfig)
        let listener = NSXPCListener(machServiceName: "com.winrun.daemon")
        listener.delegate = listenerDelegate
        listener.resume()

        // Schedule periodic cleanup of stale rate limit entries
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task {
                await service.pruneStaleClients()
            }
        }

        RunLoop.main.run()
    }
}
