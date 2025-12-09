import Foundation
import WinRunShared
import WinRunVirtualMachine
import WinRunXPC
import Security

@objc final class WinRunDaemonService: NSObject, WinRunDaemonXPC {
    private let vmController: VirtualMachineController
    private let logger: Logger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rateLimiter: RateLimiter
    
    /// Client identifier for the current request (set by connection handler)
    var currentClientId: String?

    init(
        configuration: VMConfiguration = VMConfiguration(),
        logger: Logger = StandardLogger(subsystem: "winrund"),
        throttlingConfig: ThrottlingConfig = .production
    ) {
        self.vmController = VirtualMachineController(configuration: configuration, logger: logger)
        self.logger = logger
        self.rateLimiter = RateLimiter(config: throttlingConfig, logger: logger)
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
        Task { [self] in
            do {
                try await checkThrottle()
                let request = try decode(ProgramLaunchRequest.self, from: requestData)
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
                // TODO: Query guest agent for actual sessions
                // For now, return empty list - will be populated when guest agent is connected
                let sessions = GuestSessionList(sessions: [])
                reply(try encode(sessions), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    func closeSession(_ sessionId: NSString, reply: @escaping (NSError?) -> Void) {
        Task { [self] in
            do {
                try await checkThrottle()
                let id = sessionId as String
                logger.info("Would close session \(id)")
                // TODO: Send close command to guest agent
                // For now, just acknowledge the request
                reply(nil)
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
                // TODO: Query guest agent for detected shortcuts
                // For now, return empty list - will be populated when guest agent is connected
                let shortcuts = WindowsShortcutList(shortcuts: [])
                reply(try encode(shortcuts), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    func syncShortcuts(_ destinationPath: NSString, reply: @escaping (NSData?, NSError?) -> Void) {
        Task { [self] in
            do {
                try await checkThrottle()
                let path = destinationPath as String
                logger.info("Would sync shortcuts to \(path)")
                // TODO: Fetch shortcuts from guest, create launchers
                // For now, return empty result
                let result = ShortcutSyncResult(created: 0, skipped: 0, failed: 0, launcherPaths: [])
                reply(try encode(result), nil)
            } catch {
                reply(nil, nsError(error))
            }
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> NSData {
        try NSData(data: encoder.encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: NSData) throws -> T {
        try decoder.decode(T.self, from: data as Data)
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

final class WinRunDaemonListener: NSObject, NSXPCListenerDelegate {
    private let logger: Logger
    private let service: WinRunDaemonService
    private let authConfig: XPCAuthenticationConfig

    init(service: WinRunDaemonService, logger: Logger, authConfig: XPCAuthenticationConfig = .development) {
        self.service = service
        self.logger = logger
        self.authConfig = authConfig
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let clientPid = connection.processIdentifier
        let clientUid = connection.effectiveUserIdentifier
        
        // Authenticate the connection
        do {
            try authenticateConnection(connection)
        } catch {
            logger.error("Rejected XPC connection from PID \(clientPid): \(error)")
            return false
        }
        
        // Create a per-connection service wrapper that tracks the client ID
        let connectionService = ConnectionServiceWrapper(
            service: service,
            clientId: "pid-\(clientPid)-uid-\(clientUid)"
        )
        
        connection.exportedInterface = NSXPCInterface(with: WinRunDaemonXPC.self)
        connection.exportedObject = connectionService
        
        connection.invalidationHandler = { [weak self] in
            self?.logger.debug("XPC connection from PID \(clientPid) invalidated")
        }
        
        connection.interruptionHandler = { [weak self] in
            self?.logger.warn("XPC connection from PID \(clientPid) interrupted")
        }
        
        connection.resume()
        logger.info("Accepted XPC connection from PID \(clientPid) UID \(clientUid)")
        return true
    }
    
    /// Authenticate an XPC connection based on configured policies
    private func authenticateConnection(_ connection: NSXPCConnection) throws {
        let clientPid = connection.processIdentifier
        let clientUid = connection.effectiveUserIdentifier
        
        // 1. Check group membership if configured
        if let groupName = authConfig.allowedGroupName {
            try verifyGroupMembership(uid: clientUid, groupName: groupName)
        }
        
        // 2. Verify code signature if not allowing unsigned clients
        if !authConfig.allowUnsignedClients {
            try verifyCodeSignature(pid: clientPid)
        }
        
        logger.debug("Authentication passed for PID \(clientPid)")
    }
    
    /// Verify that the user belongs to the required group
    private func verifyGroupMembership(uid: uid_t, groupName: String) throws {
        // Get the group entry
        guard let group = getgrnam(groupName) else {
            logger.warn("Group '\(groupName)' not found, skipping group check")
            return
        }
        
        let gid = group.pointee.gr_gid
        
        // Check if user's primary group matches
        guard let pwd = getpwuid(uid) else {
            throw XPCAuthenticationError.userNotInAllowedGroup(user: uid, group: groupName)
        }
        
        if pwd.pointee.pw_gid == gid {
            return // Primary group matches
        }
        
        // Check supplementary groups
        var groups = [Int32](repeating: 0, count: 64)
        var ngroups: Int32 = 64
        
        guard let username = pwd.pointee.pw_name else {
            throw XPCAuthenticationError.userNotInAllowedGroup(user: uid, group: groupName)
        }
        
        let baseGid = Int32(bitPattern: UInt32(pwd.pointee.pw_gid))
        if getgrouplist(username, baseGid, &groups, &ngroups) == -1 {
            logger.warn("Failed to get group list for UID \(uid)")
            throw XPCAuthenticationError.userNotInAllowedGroup(user: uid, group: groupName)
        }
        
        let targetGid = Int32(bitPattern: UInt32(gid))
        let userGroups = Array(groups.prefix(Int(ngroups)))
        guard userGroups.contains(targetGid) else {
            throw XPCAuthenticationError.userNotInAllowedGroup(user: uid, group: groupName)
        }
    }
    
    /// Verify the code signature of the connecting process
    private func verifyCodeSignature(pid: pid_t) throws {
        var code: SecCode?
        var status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
        
        guard status == errSecSuccess, let secCode = code else {
            throw XPCAuthenticationError.invalidCodeSignature(details: "Failed to get SecCode for PID \(pid): \(status)")
        }
        
        // Validate the code signature
        status = SecCodeCheckValidity(secCode, [], nil)
        guard status == errSecSuccess else {
            throw XPCAuthenticationError.invalidCodeSignature(details: "Code signature invalid for PID \(pid): \(status)")
        }
        
        // Convert to static code to get signing information
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(secCode, [], &staticCode)
        
        guard status == errSecSuccess, let secStaticCode = staticCode else {
            logger.debug("Could not get static code for PID \(pid), but dynamic signature is valid")
            return
        }
        
        // Get signing information
        var info: CFDictionary?
        status = SecCodeCopySigningInformation(secStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        
        guard status == errSecSuccess, let signingInfo = info as? [String: Any] else {
            logger.debug("Could not retrieve signing info for PID \(pid), but signature is valid")
            return
        }
        
        // Check team identifier if configured
        if let expectedTeamId = authConfig.teamIdentifier {
            let actualTeamId = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
            guard actualTeamId == expectedTeamId else {
                throw XPCAuthenticationError.unauthorizedTeamIdentifier(expected: expectedTeamId, actual: actualTeamId)
            }
        }
        
        // Check bundle identifier prefix
        if let bundleId = signingInfo[kSecCodeInfoIdentifier as String] as? String {
            let prefixMatch = authConfig.allowedBundleIdentifierPrefixes.contains { prefix in
                bundleId.hasPrefix(prefix)
            }
            
            // Allow if no prefixes configured or prefix matches
            if !authConfig.allowedBundleIdentifierPrefixes.isEmpty && !prefixMatch {
                throw XPCAuthenticationError.unauthorizedBundleIdentifier(identifier: bundleId)
            }
        }
    }
}

/// Wrapper that sets client ID on the service for each request
@objc final class ConnectionServiceWrapper: NSObject, WinRunDaemonXPC {
    private let service: WinRunDaemonService
    private let clientId: String
    
    init(service: WinRunDaemonService, clientId: String) {
        self.service = service
        self.clientId = clientId
    }
    
    func ensureVMRunning(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.currentClientId = clientId
        service.ensureVMRunning(reply)
    }
    
    func executeProgram(_ requestData: NSData, reply: @escaping (NSError?) -> Void) {
        service.currentClientId = clientId
        service.executeProgram(requestData, reply: reply)
    }
    
    func getStatus(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.currentClientId = clientId
        service.getStatus(reply)
    }
    
    func suspendIfIdle(_ reply: @escaping (NSError?) -> Void) {
        service.currentClientId = clientId
        service.suspendIfIdle(reply)
    }

    func stopVM(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.currentClientId = clientId
        service.stopVM(reply)
    }

    func listSessions(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.currentClientId = clientId
        service.listSessions(reply)
    }

    func closeSession(_ sessionId: NSString, reply: @escaping (NSError?) -> Void) {
        service.currentClientId = clientId
        service.closeSession(sessionId, reply: reply)
    }

    func listShortcuts(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.currentClientId = clientId
        service.listShortcuts(reply)
    }

    func syncShortcuts(_ destinationPath: NSString, reply: @escaping (NSData?, NSError?) -> Void) {
        service.currentClientId = clientId
        service.syncShortcuts(destinationPath, reply: reply)
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
