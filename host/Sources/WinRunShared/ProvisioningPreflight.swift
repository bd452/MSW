import Foundation

public enum ProvisioningPreflightResult: Equatable {
    case needsSetup(diskImagePath: URL, reason: Reason)
    case ready(configuration: VMConfiguration)

    public enum Reason: String, Equatable {
        case diskImageMissing
        case diskImageIsDirectory
        case diskImageEmpty
        case diskImageTooSmall
    }
}

public struct ProvisioningPreflight {
    public init() {}

    /// Minimum actual disk usage for a valid Windows installation (2GB).
    /// A fresh Windows 11 ARM64 install uses at least 10-15GB, but we use a lower
    /// threshold to account for compression and early setup stages.
    public static let minimumValidDiskUsageBytes: UInt64 = 2 * 1024 * 1024 * 1024

    public static func evaluate(
        configStore: ConfigStore = ConfigStore(),
        fileManager: FileManager = .default
    ) -> ProvisioningPreflightResult {
        let configuration = configStore.loadOrDefault()
        let diskURL = configuration.diskImagePath

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: diskURL.path, isDirectory: &isDirectory) else {
            return .needsSetup(diskImagePath: diskURL, reason: .diskImageMissing)
        }

        if isDirectory.boolValue {
            return .needsSetup(diskImagePath: diskURL, reason: .diskImageIsDirectory)
        }

        // Check actual disk usage (not apparent/sparse size)
        // This catches empty sparse files from failed setups
        let actualSize = actualDiskUsage(for: diskURL)
        if actualSize == 0 {
            return .needsSetup(diskImagePath: diskURL, reason: .diskImageEmpty)
        }

        if actualSize < minimumValidDiskUsageBytes {
            return .needsSetup(diskImagePath: diskURL, reason: .diskImageTooSmall)
        }

        return .ready(configuration: configuration)
    }

    /// Returns the actual disk usage in bytes (not the apparent/sparse size).
    /// For sparse files, this returns the actual allocated blocks, not the logical size.
    private static func actualDiskUsage(for url: URL) -> UInt64 {
        // Try to get the allocated size (actual disk usage for sparse files)
        if let resourceValues = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
           let allocatedSize = resourceValues.totalFileAllocatedSize {
            return UInt64(allocatedSize)
        }

        // Fallback: use file size (works for non-sparse files)
        if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = resourceValues.fileSize {
            return UInt64(fileSize)
        }

        return 0
    }
}
