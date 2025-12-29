import Foundation
import WinRunShared
import WinRunXPC
import Security

/// XPC listener delegate for the daemon.
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
            // SECURITY: Do not silently skip group check if group doesn't exist.
            // This prevents misconfiguration from bypassing authentication.
            logger.error("Required group '\(groupName)' not found on system - rejecting connection")
            throw XPCAuthenticationError.connectionRejected(
                reason: "Required group '\(groupName)' not found on system"
            )
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
        var status = SecCodeCopyGuestWithAttributes(
            nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code
        )

        guard status == errSecSuccess, let secCode = code else {
            throw XPCAuthenticationError.invalidCodeSignature(
                details: "Failed to get SecCode for PID \(pid): \(status)"
            )
        }

        // Validate the code signature
        status = SecCodeCheckValidity(secCode, [], nil)
        guard status == errSecSuccess else {
            throw XPCAuthenticationError.invalidCodeSignature(
                details: "Code signature invalid for PID \(pid): \(status)"
            )
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
        status = SecCodeCopySigningInformation(
            secStaticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        )

        guard status == errSecSuccess, let signingInfo = info as? [String: Any] else {
            logger.debug("Could not retrieve signing info for PID \(pid), but signature is valid")
            return
        }

        // Check team identifier if configured
        if let expectedTeamId = authConfig.teamIdentifier {
            let actualTeamId = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String
            guard actualTeamId == expectedTeamId else {
                throw XPCAuthenticationError.unauthorizedTeamIdentifier(
                    expected: expectedTeamId, actual: actualTeamId
                )
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

/// Wrapper that passes client ID to the service for each request.
/// Each connection gets its own wrapper instance with an immutable clientId,
/// ensuring thread-safe rate limiting across concurrent connections.
@objc final class ConnectionServiceWrapper: NSObject, WinRunDaemonXPC {
    private let service: WinRunDaemonService
    private let clientId: String

    init(service: WinRunDaemonService, clientId: String) {
        self.service = service
        self.clientId = clientId
    }

    func ensureVMRunning(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.ensureVMRunning(clientId: clientId, reply: reply)
    }

    func executeProgram(_ requestData: NSData, reply: @escaping (NSError?) -> Void) {
        service.executeProgram(clientId: clientId, requestData: requestData, reply: reply)
    }

    func getStatus(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.getStatus(clientId: clientId, reply: reply)
    }

    func suspendIfIdle(_ reply: @escaping (NSError?) -> Void) {
        service.suspendIfIdle(clientId: clientId, reply: reply)
    }

    func stopVM(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.stopVM(clientId: clientId, reply: reply)
    }

    func listSessions(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.listSessions(clientId: clientId, reply: reply)
    }

    func closeSession(_ sessionId: NSString, reply: @escaping (NSError?) -> Void) {
        service.closeSession(clientId: clientId, sessionId: sessionId as String, reply: reply)
    }

    func listShortcuts(_ reply: @escaping (NSData?, NSError?) -> Void) {
        service.listShortcuts(clientId: clientId, reply: reply)
    }

    func syncShortcuts(_ destinationPath: NSString, reply: @escaping (NSData?, NSError?) -> Void) {
        service.syncShortcuts(clientId: clientId, destinationPath: destinationPath as String, reply: reply)
    }
}
