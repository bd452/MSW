import Foundation

// MARK: - Windows Edition Info

/// Describes the Windows edition and architecture detected from an ISO.
public struct WindowsEditionInfo: Equatable, Sendable {
    /// The Windows edition name (e.g., "Windows 11 IoT Enterprise LTSC")
    public let editionName: String

    /// The full version string (e.g., "10.0.26100.1")
    public let version: String

    /// The processor architecture (e.g., "ARM64", "x64", "x86")
    public let architecture: String

    /// The build number extracted from version
    public var buildNumber: Int? {
        // Version format is typically "10.0.XXXXX.Y" where XXXXX is the build
        let components = version.split(separator: ".")
        guard components.count >= 3, let build = Int(components[2]) else {
            return nil
        }
        return build
    }

    /// Whether this is an ARM64 image
    public var isARM64: Bool {
        architecture.uppercased() == "ARM64"
    }

    /// Whether this is Windows 11
    public var isWindows11: Bool {
        guard let build = buildNumber else { return false }
        // Windows 11 starts at build 22000
        return build >= 22000
    }

    /// Whether this is an LTSC (Long-Term Servicing Channel) edition
    public var isLTSC: Bool {
        editionName.contains("LTSC")
    }

    /// Whether this is IoT Enterprise edition
    public var isIoTEnterprise: Bool {
        editionName.contains("IoT") && editionName.contains("Enterprise")
    }

    /// Whether this is a Server edition
    public var isServer: Bool {
        editionName.contains("Server")
    }

    /// Whether this is a consumer edition (Home/Pro)
    public var isConsumer: Bool {
        let lower = editionName.lowercased()
        return lower.contains("home") || (lower.contains("pro") && !lower.contains("enterprise"))
    }

    /// Whether this is the recommended edition for WinRun
    public var isRecommended: Bool {
        isARM64 && isWindows11 && isIoTEnterprise && isLTSC
    }

    public init(editionName: String, version: String, architecture: String) {
        self.editionName = editionName
        self.version = version
        self.architecture = architecture
    }
}

// MARK: - Validation Warning

/// Warning generated during ISO validation indicating potential issues.
public struct ISOValidationWarning: Equatable, Sendable {
    /// Severity of the warning
    public enum Severity: String, Sendable {
        case info
        case warning
        case critical
    }

    public let severity: Severity
    public let message: String
    public let suggestion: String?

    public init(severity: Severity, message: String, suggestion: String? = nil) {
        self.severity = severity
        self.message = message
        self.suggestion = suggestion
    }
}

// MARK: - Validation Result

/// Result of validating a Windows ISO file.
public struct ISOValidationResult: Equatable, Sendable {
    /// Path to the validated ISO file
    public let isoPath: URL

    /// Information about the Windows edition (nil if parsing failed)
    public let editionInfo: WindowsEditionInfo?

    /// Warnings generated during validation
    public let warnings: [ISOValidationWarning]

    /// Whether the ISO is usable (ARM64 architecture)
    public var isUsable: Bool {
        guard let info = editionInfo else { return false }
        return info.isARM64
    }

    /// Whether the ISO is the recommended edition
    public var isRecommended: Bool {
        editionInfo?.isRecommended ?? false
    }

    public init(isoPath: URL, editionInfo: WindowsEditionInfo?, warnings: [ISOValidationWarning]) {
        self.isoPath = isoPath
        self.editionInfo = editionInfo
        self.warnings = warnings
    }
}
