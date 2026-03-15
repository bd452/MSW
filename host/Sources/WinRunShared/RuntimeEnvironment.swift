import Foundation

public enum ServiceMode: Equatable {
    case embedded
    case xpc
}

public enum SecurityPolicy {
    case development
    case production
}

/// Centralized runtime configuration that controls both service mode
/// (embedded vs XPC) and security policy (dev vs prod auth/throttling).
///
/// Reads from `WINRUN_ENV` environment variable, falling back to a
/// compile-time default (`development` for debug, `production` for release).
///
/// Usage:
///   - `RuntimeEnvironment.current.serviceMode` -- `.embedded` or `.xpc`
///   - `RuntimeEnvironment.current.authConfig` -- XPC authentication config
///   - Override at launch: `WINRUN_ENV=production ./WinRunApp`
public enum RuntimeEnvironment: String {
    case development
    case production

    public var serviceMode: ServiceMode {
        switch self {
        case .development: return .embedded
        case .production: return .xpc
        }
    }

    public var securityPolicy: SecurityPolicy {
        switch self {
        case .development: return .development
        case .production: return .production
        }
    }

    public var authConfig: XPCAuthenticationConfig {
        switch securityPolicy {
        case .development: return .development
        case .production: return .production
        }
    }

    public var throttlingConfig: ThrottlingConfig {
        switch securityPolicy {
        case .development: return .development
        case .production: return .production
        }
    }

    public static let current: RuntimeEnvironment = resolveEnvironment()

    private static func resolveEnvironment() -> RuntimeEnvironment {
        if let raw = ProcessInfo.processInfo.environment["WINRUN_ENV"],
           let env = RuntimeEnvironment(rawValue: raw) {
            return env
        }
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }
}
