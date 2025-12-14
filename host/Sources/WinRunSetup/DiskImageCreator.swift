import Foundation
import WinRunShared

// MARK: - Disk Image Configuration

/// Configuration for creating a VM disk image.
public struct DiskImageConfiguration: Equatable, Sendable {
    /// The destination path for the disk image.
    public let destinationURL: URL

    /// The disk size in gigabytes.
    public let sizeGB: UInt64

    /// Whether to overwrite an existing disk image at the destination.
    public let overwriteExisting: Bool

    /// Default disk size in GB (64GB as per provisioning docs).
    public static let defaultSizeGB: UInt64 = 64

    /// Minimum supported disk size in GB.
    public static let minimumSizeGB: UInt64 = 32

    /// Maximum supported disk size in GB (2TB).
    public static let maximumSizeGB: UInt64 = 2048

    /// Default disk image filename.
    public static let defaultFilename = "windows.img"

    /// Default directory for WinRun data.
    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("WinRun", isDirectory: true)
    }

    /// Default disk image path.
    public static var defaultPath: URL {
        defaultDirectory.appendingPathComponent(defaultFilename)
    }

    /// Creates a disk image configuration with the specified parameters.
    ///
    /// - Parameters:
    ///   - destinationURL: Where to create the disk image. Defaults to the standard WinRun location.
    ///   - sizeGB: Size in gigabytes. Defaults to 64GB.
    ///   - overwriteExisting: Whether to overwrite an existing file. Defaults to false.
    public init(
        destinationURL: URL? = nil,
        sizeGB: UInt64 = DiskImageConfiguration.defaultSizeGB,
        overwriteExisting: Bool = false
    ) {
        self.destinationURL = destinationURL ?? Self.defaultPath
        self.sizeGB = sizeGB
        self.overwriteExisting = overwriteExisting
    }
}

// MARK: - Disk Image Creation Result

/// Result of a disk image creation operation.
public struct DiskImageResult: Equatable, Sendable {
    /// The path to the created disk image.
    public let path: URL

    /// The configured size in bytes.
    public let sizeBytes: UInt64

    /// Whether the file was created as sparse (hole-punched).
    public let isSparse: Bool

    /// The actual size on disk in bytes (may be less than sizeBytes for sparse files).
    public let allocatedBytes: UInt64

    public init(path: URL, sizeBytes: UInt64, isSparse: Bool, allocatedBytes: UInt64) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.isSparse = isSparse
        self.allocatedBytes = allocatedBytes
    }
}

// MARK: - Disk Image Creator

/// Creates and manages VM disk images.
///
/// `DiskImageCreator` creates sparse disk images suitable for use with
/// macOS Virtualization.framework. Sparse images only consume actual disk
/// space as data is written to them, making initial creation fast and
/// storage-efficient.
///
/// ## Example
/// ```swift
/// let creator = DiskImageCreator()
/// let config = DiskImageConfiguration(sizeGB: 128)
/// let result = try await creator.createDiskImage(configuration: config)
/// print("Created disk at \(result.path)")
/// ```
public final class DiskImageCreator: Sendable {
    /// File manager used for disk operations.
    /// - Note: FileManager.default is thread-safe for the operations we perform.
    private nonisolated(unsafe) let fileManager: FileManager

    /// Creates a new disk image creator.
    ///
    /// - Parameter fileManager: File manager to use for operations. Defaults to `.default`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Creates a sparse disk image with the specified configuration.
    ///
    /// The disk image is created as a sparse file, meaning it only consumes
    /// actual disk space as data is written to it. A 64GB sparse disk image
    /// initially uses almost no disk space.
    ///
    /// - Parameter configuration: The disk image configuration.
    /// - Returns: Information about the created disk image.
    /// - Throws: `WinRunError` if the disk image cannot be created.
    public func createDiskImage(
        configuration: DiskImageConfiguration
    ) async throws -> DiskImageResult {
        // Validate size
        try validateSize(configuration.sizeGB)

        let destinationURL = configuration.destinationURL
        let sizeBytes = configuration.sizeGB * 1024 * 1024 * 1024

        // Check if file already exists
        if fileManager.fileExists(atPath: destinationURL.path) {
            if configuration.overwriteExisting {
                try removeExisting(at: destinationURL)
            } else {
                throw WinRunError.diskAlreadyExists(path: destinationURL.path)
            }
        }

        // Ensure parent directory exists
        try createParentDirectory(for: destinationURL)

        // Check available disk space
        try checkAvailableSpace(at: destinationURL, requiredGB: configuration.sizeGB)

        // Create the sparse disk image
        try createSparseFile(at: destinationURL, sizeBytes: sizeBytes)

        // Get actual allocated size
        let allocatedBytes = try getAllocatedSize(at: destinationURL)

        return DiskImageResult(
            path: destinationURL,
            sizeBytes: sizeBytes,
            isSparse: allocatedBytes < sizeBytes,
            allocatedBytes: allocatedBytes
        )
    }

    /// Deletes a disk image at the specified path.
    ///
    /// - Parameter url: The path to the disk image to delete.
    /// - Throws: An error if the file cannot be deleted.
    public func deleteDiskImage(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Checks if a disk image exists at the specified path.
    ///
    /// - Parameter url: The path to check.
    /// - Returns: `true` if a file exists at the path.
    public func diskImageExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// Gets information about an existing disk image.
    ///
    /// - Parameter url: The path to the disk image.
    /// - Returns: Information about the disk image, or `nil` if it doesn't exist.
    public func getDiskImageInfo(at url: URL) throws -> DiskImageResult? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let sizeBytes = attributes[.size] as? UInt64 else {
            return nil
        }

        let allocatedBytes = try getAllocatedSize(at: url)

        return DiskImageResult(
            path: url,
            sizeBytes: sizeBytes,
            isSparse: allocatedBytes < sizeBytes,
            allocatedBytes: allocatedBytes
        )
    }

    // MARK: - Private Helpers

    private func validateSize(_ sizeGB: UInt64) throws {
        if sizeGB < DiskImageConfiguration.minimumSizeGB {
            throw WinRunError.diskInvalidSize(
                sizeGB: sizeGB,
                reason: "Minimum size is \(DiskImageConfiguration.minimumSizeGB)GB"
            )
        }
        if sizeGB > DiskImageConfiguration.maximumSizeGB {
            throw WinRunError.diskInvalidSize(
                sizeGB: sizeGB,
                reason: "Maximum size is \(DiskImageConfiguration.maximumSizeGB)GB"
            )
        }
    }

    private func removeExisting(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw WinRunError.diskCreationFailed(
                path: url.path,
                reason: "Could not remove existing file: \(error.localizedDescription)"
            )
        }
    }

    private func createParentDirectory(for url: URL) throws {
        let parentDirectory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            do {
                try fileManager.createDirectory(
                    at: parentDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw WinRunError.diskCreationFailed(
                    path: url.path,
                    reason: "Could not create parent directory: \(error.localizedDescription)"
                )
            }
        }
    }

    private func checkAvailableSpace(at url: URL, requiredGB: UInt64) throws {
        let parentDirectory = url.deletingLastPathComponent()
        let attributes = try fileManager.attributesOfFileSystem(forPath: parentDirectory.path)

        guard let freeSpace = attributes[.systemFreeSize] as? UInt64 else {
            return  // Skip check if we can't determine free space
        }

        let freeSpaceGB = freeSpace / (1024 * 1024 * 1024)

        // For sparse files, we only need a small amount of space initially
        // but we warn if there's not enough space for the full disk
        // We require at least 1GB free for the initial creation plus overhead
        let minimumRequired: UInt64 = 1

        if freeSpaceGB < minimumRequired {
            throw WinRunError.diskInsufficientSpace(
                requiredGB: minimumRequired,
                availableGB: freeSpaceGB
            )
        }
    }

    private func createSparseFile(at url: URL, sizeBytes: UInt64) throws {
        // Create a sparse file by:
        // 1. Creating an empty file
        // 2. Truncating it to the desired size (this creates a sparse file on APFS/HFS+)
        let created = fileManager.createFile(atPath: url.path, contents: nil, attributes: nil)
        guard created else {
            throw WinRunError.diskCreationFailed(
                path: url.path,
                reason: "Could not create file"
            )
        }

        // Open the file and set its size using truncation
        guard let fileHandle = FileHandle(forWritingAtPath: url.path) else {
            try? fileManager.removeItem(at: url)
            throw WinRunError.diskCreationFailed(
                path: url.path,
                reason: "Could not open file for writing"
            )
        }

        defer { try? fileHandle.close() }

        do {
            // truncate creates a sparse file on APFS
            try fileHandle.truncate(atOffset: sizeBytes)
        } catch {
            try? fileManager.removeItem(at: url)
            throw WinRunError.diskCreationFailed(
                path: url.path,
                reason: "Could not set file size: \(error.localizedDescription)"
            )
        }
    }

    private func getAllocatedSize(at url: URL) throws -> UInt64 {
        // Use the file's allocated size attribute to determine actual disk usage
        let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(resourceValues.totalFileAllocatedSize ?? 0)
    }
}
