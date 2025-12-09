import Foundation

public struct VMResources: Codable, Hashable {
    public let cpuCount: Int
    public let memorySizeGB: Int

    public init(cpuCount: Int = 4, memorySizeGB: Int = 4) {
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
    }
}

public struct VMDiskConfiguration: Codable, Hashable {
    public var imagePath: URL
    public var sizeGB: Int

    public init(
        imagePath: URL = VMDiskConfiguration.defaultImagePath,
        sizeGB: Int = 64
    ) {
        self.imagePath = imagePath
        self.sizeGB = sizeGB
    }

    public static var defaultImagePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WinRun/windows.img")
    }
}

public enum VMNetworkAttachmentMode: String, Codable, CaseIterable, Hashable {
    case nat
    case bridged
}

public struct VMNetworkConfiguration: Codable, Hashable {
    public var mode: VMNetworkAttachmentMode
    public var interfaceIdentifier: String?
    public var macAddress: String?

    public init(
        mode: VMNetworkAttachmentMode = .nat,
        interfaceIdentifier: String? = nil,
        macAddress: String? = nil
    ) {
        self.mode = mode
        self.interfaceIdentifier = interfaceIdentifier
        self.macAddress = macAddress
    }
}

public struct VMConfiguration: Codable, Hashable {
    public var resources: VMResources
    public var disk: VMDiskConfiguration
    public var network: VMNetworkConfiguration
    public var suspendOnIdleAfterSeconds: TimeInterval

    public init(
        resources: VMResources = VMResources(),
        disk: VMDiskConfiguration = VMDiskConfiguration(),
        network: VMNetworkConfiguration = VMNetworkConfiguration(),
        suspendOnIdleAfterSeconds: TimeInterval = 300
    ) {
        self.resources = resources
        self.disk = disk
        self.network = network
        self.suspendOnIdleAfterSeconds = suspendOnIdleAfterSeconds
    }

    public var diskImagePath: URL {
        get { disk.imagePath }
        set { disk.imagePath = newValue }
    }
}

public enum VMConfigurationValidationError: Error, CustomStringConvertible {
    case cpuCountOutOfRange(actual: Int, allowed: ClosedRange<Int>)
    case memoryOutOfRange(actual: Int, allowed: ClosedRange<Int>)
    case diskDirectoryUnavailable(URL)
    case diskImageMissing(URL)
    case diskImageIsDirectory(URL)
    case diskSizeTooSmall(actual: Int)
    case bridgedInterfaceNotSpecified
    case bridgedInterfaceUnavailable(String)

    public var description: String {
        switch self {
        case .cpuCountOutOfRange(let actual, let allowed):
            return "CPU count \(actual) is outside of supported range \(allowed.lowerBound)-\(allowed.upperBound)."
        case .memoryOutOfRange(let actual, let allowed):
            return "Memory \(actual)GB falls outside of supported range \(allowed.lowerBound)-\(allowed.upperBound)GB."
        case .diskDirectoryUnavailable(let url):
            return "Disk directory \(url.path) is unavailable or cannot be created."
        case .diskImageMissing(let url):
            return "Disk image \(url.path) is missing. Run winrun init to provision Windows."
        case .diskImageIsDirectory(let url):
            return "Disk image path \(url.path) points to a directory, expected file."
        case .diskSizeTooSmall(let actual):
            return "Configured disk size \(actual)GB is below the minimum of 32GB."
        case .bridgedInterfaceNotSpecified:
            return "Bridged networking requires an interface identifier."
        case .bridgedInterfaceUnavailable(let identifier):
            return "Bridged interface \(identifier) was not found on this host."
        }
    }
}

public extension VMResources {
    static let supportedCPURange = 2...32
    static let supportedMemoryRangeGB = 4...64

    func validate() throws {
        if !VMResources.supportedCPURange.contains(cpuCount) {
            throw VMConfigurationValidationError.cpuCountOutOfRange(
                actual: cpuCount,
                allowed: VMResources.supportedCPURange
            )
        }
        if !VMResources.supportedMemoryRangeGB.contains(memorySizeGB) {
            throw VMConfigurationValidationError.memoryOutOfRange(
                actual: memorySizeGB,
                allowed: VMResources.supportedMemoryRangeGB
            )
        }
    }
}

public extension VMDiskConfiguration {
    private var minimumSizeGB: Int { 32 }

    func validate(fileManager: FileManager = .default) throws {
        guard sizeGB >= minimumSizeGB else {
            throw VMConfigurationValidationError.diskSizeTooSmall(actual: sizeGB)
        }

        let directoryURL = imagePath.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                throw VMConfigurationValidationError.diskDirectoryUnavailable(directoryURL)
            }
        } else if !isDirectory.boolValue {
            throw VMConfigurationValidationError.diskDirectoryUnavailable(directoryURL)
        }

        var isImageDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: imagePath.path, isDirectory: &isImageDirectory) else {
            throw VMConfigurationValidationError.diskImageMissing(imagePath)
        }

        if isImageDirectory.boolValue {
            throw VMConfigurationValidationError.diskImageIsDirectory(imagePath)
        }
    }
}

public extension VMNetworkConfiguration {
    func validate() throws {
        if mode == .bridged, (interfaceIdentifier?.isEmpty ?? true) {
            throw VMConfigurationValidationError.bridgedInterfaceNotSpecified
        }
    }
}

public extension VMConfiguration {
    func validate(fileManager: FileManager = .default) throws {
        try resources.validate()
        try disk.validate(fileManager: fileManager)
        try network.validate()
    }
}

public enum WinRunError: Error, CustomStringConvertible {
    case vmNotInitialized
    case launchFailed(reason: String)
    case invalidExecutable
    case ipcFailure

    public var description: String {
        switch self {
        case .vmNotInitialized:
            return "Windows VM has not completed initial provisioning."
        case .launchFailed(let reason):
            return "Failed to launch program: \(reason)"
        case .invalidExecutable:
            return "Provided executable path is invalid or missing."
        case .ipcFailure:
            return "Unable to reach winrund daemon. Is it running?"
        }
    }
}

public struct ProgramLaunchRequest: Codable, Hashable {
    public let windowsPath: String
    public let arguments: [String]
    public let workingDirectory: String?

    public init(windowsPath: String, arguments: [String] = [], workingDirectory: String? = nil) {
        self.windowsPath = windowsPath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public enum VMStatus: String, Codable {
    case stopped
    case starting
    case running
    case suspending
    case suspended
    case stopping
}

public struct VMState: Codable {
    public var status: VMStatus
    public var uptime: TimeInterval
    public var activeSessions: Int

    public init(status: VMStatus, uptime: TimeInterval, activeSessions: Int) {
        self.status = status
        self.uptime = uptime
        self.activeSessions = activeSessions
    }
}

public struct VMMetricsSnapshot: Codable, CustomStringConvertible {
    public let event: String
    public let uptimeSeconds: TimeInterval
    public let activeSessions: Int
    public let totalSessions: Int
    public let bootCount: Int
    public let suspendCount: Int

    public init(
        event: String,
        uptimeSeconds: TimeInterval,
        activeSessions: Int,
        totalSessions: Int,
        bootCount: Int,
        suspendCount: Int
    ) {
        self.event = event
        self.uptimeSeconds = uptimeSeconds
        self.activeSessions = activeSessions
        self.totalSessions = totalSessions
        self.bootCount = bootCount
        self.suspendCount = suspendCount
    }

    public var description: String {
        let uptimeString = String(format: "%.2fs", uptimeSeconds)
        return "event=\(event) uptime=\(uptimeString) activeSessions=\(activeSessions) totalSessions=\(totalSessions) boots=\(bootCount) suspends=\(suspendCount)"
    }
}

public struct SpiceStreamMetrics: Codable, Hashable {
    public var framesReceived: Int
    public var metadataUpdates: Int
    public var reconnectAttempts: Int
    public var lastErrorDescription: String?

    public init(
        framesReceived: Int = 0,
        metadataUpdates: Int = 0,
        reconnectAttempts: Int = 0,
        lastErrorDescription: String? = nil
    ) {
        self.framesReceived = framesReceived
        self.metadataUpdates = metadataUpdates
        self.reconnectAttempts = reconnectAttempts
        self.lastErrorDescription = lastErrorDescription
    }
}

public protocol Logger {
    func debug(_ message: String)
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

public struct StandardLogger: Logger {
    private let subsystem: String

    public init(subsystem: String) {
        self.subsystem = subsystem
    }

    public func debug(_ message: String) {
        print("[DEBUG][\(subsystem)] \(message)")
    }

    public func info(_ message: String) {
        print("[INFO][\(subsystem)] \(message)")
    }

    public func warn(_ message: String) {
        print("[WARN][\(subsystem)] \(message)")
    }

    public func error(_ message: String) {
        print("[ERROR][\(subsystem)] \(message)")
    }
}

// MARK: - XPC Authentication

/// Configuration for XPC caller authentication
public struct XPCAuthenticationConfig: Codable, Hashable {
    /// Team identifier for code signing verification (e.g., "ABCD1234EF")
    public var teamIdentifier: String?
    
    /// Bundle identifier prefixes allowed to connect
    public var allowedBundleIdentifierPrefixes: [String]
    
    /// Unix group name for group membership checks
    public var allowedGroupName: String?
    
    /// Whether to allow unsigned binaries (development only)
    public var allowUnsignedClients: Bool
    
    public init(
        teamIdentifier: String? = nil,
        allowedBundleIdentifierPrefixes: [String] = ["com.winrun."],
        allowedGroupName: String? = "staff",
        allowUnsignedClients: Bool = false
    ) {
        self.teamIdentifier = teamIdentifier
        self.allowedBundleIdentifierPrefixes = allowedBundleIdentifierPrefixes
        self.allowedGroupName = allowedGroupName
        self.allowUnsignedClients = allowUnsignedClients
    }
    
    /// Default development configuration (more permissive)
    public static var development: XPCAuthenticationConfig {
        XPCAuthenticationConfig(
            allowedBundleIdentifierPrefixes: ["com.winrun."],
            allowedGroupName: "staff",
            allowUnsignedClients: true
        )
    }
    
    /// Production configuration (stricter)
    public static var production: XPCAuthenticationConfig {
        XPCAuthenticationConfig(
            teamIdentifier: nil, // Set to actual team ID in production
            allowedBundleIdentifierPrefixes: ["com.winrun."],
            allowedGroupName: "staff",
            allowUnsignedClients: false
        )
    }
}

/// Errors related to XPC authentication
public enum XPCAuthenticationError: Error, CustomStringConvertible {
    case connectionRejected(reason: String)
    case invalidCodeSignature(details: String)
    case unauthorizedTeamIdentifier(expected: String?, actual: String?)
    case unauthorizedBundleIdentifier(identifier: String)
    case userNotInAllowedGroup(user: uid_t, group: String)
    case throttled(retryAfterSeconds: TimeInterval)
    
    public var description: String {
        switch self {
        case .connectionRejected(let reason):
            return "XPC connection rejected: \(reason)"
        case .invalidCodeSignature(let details):
            return "Invalid code signature: \(details)"
        case .unauthorizedTeamIdentifier(let expected, let actual):
            return "Unauthorized team identifier. Expected: \(expected ?? "any"), got: \(actual ?? "none")"
        case .unauthorizedBundleIdentifier(let identifier):
            return "Bundle identifier '\(identifier)' is not authorized to connect."
        case .userNotInAllowedGroup(let user, let group):
            return "User \(user) is not a member of required group '\(group)'."
        case .throttled(let seconds):
            return "Request throttled. Retry after \(String(format: "%.1f", seconds)) seconds."
        }
    }
}

// MARK: - Request Throttling

/// Configuration for request rate limiting
public struct ThrottlingConfig: Codable, Hashable {
    /// Maximum requests allowed per window
    public var maxRequestsPerWindow: Int
    
    /// Time window in seconds
    public var windowSeconds: TimeInterval
    
    /// Burst allowance (additional requests permitted for short bursts)
    public var burstAllowance: Int
    
    /// Cooldown period after hitting rate limit
    public var cooldownSeconds: TimeInterval
    
    public init(
        maxRequestsPerWindow: Int = 60,
        windowSeconds: TimeInterval = 60,
        burstAllowance: Int = 10,
        cooldownSeconds: TimeInterval = 5
    ) {
        self.maxRequestsPerWindow = maxRequestsPerWindow
        self.windowSeconds = windowSeconds
        self.burstAllowance = burstAllowance
        self.cooldownSeconds = cooldownSeconds
    }
    
    /// Permissive config for development
    public static var development: ThrottlingConfig {
        ThrottlingConfig(
            maxRequestsPerWindow: 1000,
            windowSeconds: 60,
            burstAllowance: 100,
            cooldownSeconds: 1
        )
    }
    
    /// Stricter production config
    public static var production: ThrottlingConfig {
        ThrottlingConfig(
            maxRequestsPerWindow: 120,
            windowSeconds: 60,
            burstAllowance: 20,
            cooldownSeconds: 5
        )
    }
}

/// Token bucket rate limiter for request throttling
public actor RateLimiter {
    private let config: ThrottlingConfig
    private var clientBuckets: [String: TokenBucket] = [:]
    private let logger: Logger?
    
    public init(config: ThrottlingConfig = .production, logger: Logger? = nil) {
        self.config = config
        self.logger = logger
    }
    
    /// Check if a request should be allowed for the given client identifier
    /// - Parameter clientId: Unique identifier for the client (e.g., PID or audit token hash)
    /// - Returns: Result indicating success or throttling error with retry time
    public func checkRequest(clientId: String) -> Result<Void, XPCAuthenticationError> {
        let now = Date()
        
        // Get or create bucket for this client
        if clientBuckets[clientId] == nil {
            let capacity = Double(config.maxRequestsPerWindow + config.burstAllowance)
            clientBuckets[clientId] = TokenBucket(
                capacity: capacity,
                refillRate: Double(config.maxRequestsPerWindow) / config.windowSeconds,
                tokens: capacity,
                lastRefill: now,
                cooldownUntil: nil
            )
        }
        
        guard var bucket = clientBuckets[clientId] else {
            return .success(())
        }
        
        // Check cooldown
        if let cooldownUntil = bucket.cooldownUntil, now < cooldownUntil {
            let retryAfter = cooldownUntil.timeIntervalSince(now)
            logger?.warn("Client \(clientId) is in cooldown for \(String(format: "%.1f", retryAfter))s")
            return .failure(.throttled(retryAfterSeconds: retryAfter))
        }
        
        // Refill tokens based on elapsed time
        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        let tokensToAdd = elapsed * bucket.refillRate
        bucket.tokens = min(bucket.capacity, bucket.tokens + tokensToAdd)
        bucket.lastRefill = now
        
        // Try to consume a token
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0
            bucket.cooldownUntil = nil
            clientBuckets[clientId] = bucket
            return .success(())
        } else {
            // Rate limited - enter cooldown
            bucket.cooldownUntil = now.addingTimeInterval(config.cooldownSeconds)
            clientBuckets[clientId] = bucket
            logger?.warn("Client \(clientId) exceeded rate limit, entering cooldown")
            return .failure(.throttled(retryAfterSeconds: config.cooldownSeconds))
        }
    }
    
    /// Remove stale client entries to prevent memory growth
    public func pruneStaleClients(olderThan age: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-age)
        clientBuckets = clientBuckets.filter { $0.value.lastRefill > cutoff }
    }
    
    /// Get current metrics for monitoring
    public func metrics() -> ThrottlingMetrics {
        ThrottlingMetrics(
            activeClients: clientBuckets.count,
            clientsInCooldown: clientBuckets.values.filter { bucket in
                if let cooldown = bucket.cooldownUntil {
                    return Date() < cooldown
                }
                return false
            }.count
        )
    }
}

/// Internal token bucket state
private struct TokenBucket {
    var capacity: Double
    var refillRate: Double  // tokens per second
    var tokens: Double
    var lastRefill: Date
    var cooldownUntil: Date?
}

/// Metrics snapshot for throttling state
public struct ThrottlingMetrics: Codable {
    public let activeClients: Int
    public let clientsInCooldown: Int
}
