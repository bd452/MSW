import Foundation

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
