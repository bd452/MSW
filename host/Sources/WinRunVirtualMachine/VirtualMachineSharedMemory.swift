import Foundation
import WinRunShared
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Virtualization)
import Virtualization
#endif

// MARK: - Shared Memory Region

/// A memory-mapped region shared between host and guest for frame buffers.
public final class SharedMemoryRegion {
    /// URL of the shared memory file
    public let fileURL: URL
    /// Size of the region in bytes
    public let size: Int
    /// Pointer to the mapped memory (host-side)
    public let pointer: UnsafeMutableRawPointer
    /// File handle for the mapped file
    private let fileHandle: FileHandle
    /// Whether this region owns the file and should clean up on deinit
    private let ownsFile: Bool

    init(fileURL: URL, size: Int, pointer: UnsafeMutableRawPointer, fileHandle: FileHandle, ownsFile: Bool = true) {
        self.fileURL = fileURL
        self.size = size
        self.pointer = pointer
        self.fileHandle = fileHandle
        self.ownsFile = ownsFile
    }

    deinit {
        // Unmap the memory
        munmap(pointer, size)

        // Close the file handle
        try? fileHandle.close()

        // Remove the file if we own it
        if ownsFile {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// The path relative to the shared directory (for guest access).
    /// The guest accesses this via VirtioFS mount.
    public var guestRelativePath: String {
        fileURL.lastPathComponent
    }
}

// MARK: - Shared Memory Errors

/// Errors that can occur during shared memory operations.
public enum SharedMemoryError: Error, CustomStringConvertible {
    case directoryCreationFailed(URL, Error)
    case fileCreationFailed(URL, Error)
    case fileTruncationFailed(URL, Error)
    case memoryMappingFailed(URL, String)
    case regionNotInitialized

    public var description: String {
        switch self {
        case .directoryCreationFailed(let url, let error):
            return "Failed to create shared memory directory at \(url.path): \(error.localizedDescription)"
        case .fileCreationFailed(let url, let error):
            return "Failed to create shared memory file at \(url.path): \(error.localizedDescription)"
        case .fileTruncationFailed(let url, let error):
            return "Failed to set shared memory file size at \(url.path): \(error.localizedDescription)"
        case .memoryMappingFailed(let url, let reason):
            return "Failed to memory-map \(url.path): \(reason)"
        case .regionNotInitialized:
            return "Shared memory region has not been initialized"
        }
    }
}

// MARK: - Shared Memory Manager

/// Manages shared memory regions for frame buffer transfer.
public final class SharedMemoryManager {
    private let logger: Logger
    private let baseDirectory: URL

    /// Active shared memory region (if initialized)
    private var activeRegion: SharedMemoryRegion?

    /// Tag for VirtioFS share (must match guest mount)
    public static let virtioFSTag = "winrun-framebuffer"

    /// Default shared memory directory under Application Support
    public static var defaultBaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WinRun/SharedMemory")
    }

    public init(
        baseDirectory: URL = SharedMemoryManager.defaultBaseDirectory,
        logger: Logger = StandardLogger(subsystem: "SharedMemory")
    ) {
        self.baseDirectory = baseDirectory
        self.logger = logger
    }

    /// Creates and maps a shared memory region for frame buffers.
    /// - Parameter sizeMB: Size in megabytes
    /// - Returns: The created shared memory region
    public func createRegion(sizeMB: Int) throws -> SharedMemoryRegion {
        // Clean up any existing region
        activeRegion = nil

        // Ensure the directory exists
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            do {
                try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
                logger.debug("Created shared memory directory: \(baseDirectory.path)")
            } catch {
                throw SharedMemoryError.directoryCreationFailed(baseDirectory, error)
            }
        }

        // Create the shared memory file
        let sizeBytes = sizeMB * 1024 * 1024
        let fileURL = baseDirectory.appendingPathComponent("framebuffer.shm")

        // Remove existing file if present
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }

        // Create the file
        guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
            throw SharedMemoryError.fileCreationFailed(fileURL, NSError(domain: "SharedMemory", code: -1))
        }

        // Open the file for read/write
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forUpdating: fileURL)
        } catch {
            throw SharedMemoryError.fileCreationFailed(fileURL, error)
        }

        // Truncate to the desired size (creates sparse file)
        do {
            try fileHandle.truncate(atOffset: UInt64(sizeBytes))
        } catch {
            try? fileHandle.close()
            throw SharedMemoryError.fileTruncationFailed(fileURL, error)
        }

        // Memory-map the file
        let fd = fileHandle.fileDescriptor
        let pointer = mmap(
            nil,
            sizeBytes,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0
        )

        guard pointer != MAP_FAILED else {
            let errorCode = errno
            try? fileHandle.close()
            throw SharedMemoryError.memoryMappingFailed(
                fileURL,
                "mmap failed with error code \(errorCode): \(String(cString: strerror(errorCode)))"
            )
        }

        // Initialize the header
        let region = SharedMemoryRegion(
            fileURL: fileURL,
            size: sizeBytes,
            pointer: pointer!,
            fileHandle: fileHandle
        )

        activeRegion = region
        logger.info("Created shared memory region: \(sizeMB) MB at \(fileURL.path)")

        return region
    }

    /// Gets the current active shared memory region.
    public func currentRegion() -> SharedMemoryRegion? {
        activeRegion
    }

    /// Gets the base directory path (for VirtioFS sharing).
    public var sharedDirectoryPath: URL {
        baseDirectory
    }

    /// Cleans up all shared memory resources.
    public func cleanup() {
        if activeRegion != nil {
            logger.debug("Cleaning up shared memory region")
            activeRegion = nil
        }
    }
}

// MARK: - VirtualMachineController Extension

extension VirtualMachineController {
    /// The shared memory manager for this VM.
    /// This is created lazily when shared memory is first accessed.
    private static var sharedMemoryManagers = [ObjectIdentifier: SharedMemoryManager]()
    private static let managerLock = NSLock()

    /// Gets or creates the shared memory manager for this controller.
    private var sharedMemoryManager: SharedMemoryManager {
        let id = ObjectIdentifier(self)
        Self.managerLock.lock()
        defer { Self.managerLock.unlock() }

        if let existing = Self.sharedMemoryManagers[id] {
            return existing
        }

        let manager = SharedMemoryManager()
        Self.sharedMemoryManagers[id] = manager
        return manager
    }

    /// Initializes the shared memory region for frame buffers.
    /// Call this after the VM is configured but before starting.
    /// - Returns: The created shared memory region
    public func initializeSharedMemory() throws -> SharedMemoryRegion {
        let config = frameStreamingConfiguration
        guard config.sharedMemoryEnabled else {
            throw SharedMemoryError.regionNotInitialized
        }

        return try sharedMemoryManager.createRegion(sizeMB: config.sharedMemorySizeMB)
    }

    /// Gets the current shared memory region, if initialized.
    public func getSharedMemoryRegion() -> SharedMemoryRegion? {
        sharedMemoryManager.currentRegion()
    }

    /// Gets the directory path for VirtioFS sharing.
    public func getSharedMemoryDirectory() -> URL {
        sharedMemoryManager.sharedDirectoryPath
    }

    /// Cleans up shared memory resources.
    /// Called automatically when the VM is stopped.
    public func cleanupSharedMemory() {
        let id = ObjectIdentifier(self)
        Self.managerLock.lock()
        defer { Self.managerLock.unlock() }

        if let manager = Self.sharedMemoryManagers.removeValue(forKey: id) {
            manager.cleanup()
        }
    }
}

#if canImport(Virtualization)
// MARK: - VirtioFS Configuration Helper

@available(macOS 13, *)
extension VirtualMachineController {
    /// Creates a VirtioFS device configuration for sharing the frame buffer directory.
    /// - Returns: The configured VirtioFS device
    public func createFrameBufferShareDevice() throws -> VZVirtioFileSystemDeviceConfiguration {
        let directory = getSharedMemoryDirectory()

        // Ensure the directory exists
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Create the share using VZSharedDirectory
        let sharedDirectory = VZSharedDirectory(url: directory, readOnly: false)
        let directoryShare = VZSingleDirectoryShare(directory: sharedDirectory)

        // Create the VirtioFS device
        let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: SharedMemoryManager.virtioFSTag)
        fsDevice.share = directoryShare

        return fsDevice
    }
}
#endif
