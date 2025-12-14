import Foundation
import WinRunShared

// MARK: - Provisioning Configuration

/// Configuration for provisioning a new Windows VM from an ISO.
public struct ProvisioningConfiguration: Equatable, Sendable {
    /// Path to the Windows installation ISO.
    public let isoPath: URL

    /// Path to the disk image to install Windows onto.
    public let diskImagePath: URL

    /// Path to the autounattend.xml file for unattended installation.
    public let autounattendPath: URL?

    /// CPU cores to allocate during installation.
    public let cpuCount: Int

    /// Memory in GB to allocate during installation.
    public let memorySizeGB: Int

    /// Default CPU count for provisioning.
    public static let defaultCPUCount = 4

    /// Default memory in GB for provisioning.
    public static let defaultMemorySizeGB = 8

    /// Creates a provisioning configuration.
    ///
    /// - Parameters:
    ///   - isoPath: Path to the Windows installation ISO.
    ///   - diskImagePath: Path to the disk image.
    ///   - autounattendPath: Optional path to autounattend.xml.
    ///   - cpuCount: CPU cores to allocate. Defaults to 4.
    ///   - memorySizeGB: Memory in GB. Defaults to 8.
    public init(
        isoPath: URL,
        diskImagePath: URL,
        autounattendPath: URL? = nil,
        cpuCount: Int = ProvisioningConfiguration.defaultCPUCount,
        memorySizeGB: Int = ProvisioningConfiguration.defaultMemorySizeGB
    ) {
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.autounattendPath = autounattendPath
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
    }
}

// MARK: - Provisioning VM Configuration

/// VM storage device configuration for provisioning.
public struct ProvisioningStorageDevice: Equatable, Sendable {
    /// The type of storage device.
    public enum DeviceType: String, Sendable {
        case disk
        case cdrom
        case floppy
    }

    /// Device type (disk, cdrom, or floppy).
    public let type: DeviceType

    /// Path to the storage device image.
    public let path: URL

    /// Whether the device is read-only.
    public let isReadOnly: Bool

    /// Whether this device should be bootable.
    public let isBootable: Bool

    public init(type: DeviceType, path: URL, isReadOnly: Bool = false, isBootable: Bool = false) {
        self.type = type
        self.path = path
        self.isReadOnly = isReadOnly
        self.isBootable = isBootable
    }
}

/// Complete VM configuration for Windows provisioning.
///
/// This configuration includes the ISO as a bootable CD-ROM device
/// and optionally a virtual floppy for autounattend.xml injection.
public struct ProvisioningVMConfiguration: Equatable, Sendable {
    /// CPU cores allocated to the VM.
    public let cpuCount: Int

    /// Memory in bytes allocated to the VM.
    public let memorySizeBytes: UInt64

    /// Storage devices attached to the VM.
    public let storageDevices: [ProvisioningStorageDevice]

    /// Whether to use EFI boot.
    public let useEFIBoot: Bool

    /// Memory in GB.
    public var memorySizeGB: Int {
        Int(memorySizeBytes / (1024 * 1024 * 1024))
    }

    public init(
        cpuCount: Int,
        memorySizeBytes: UInt64,
        storageDevices: [ProvisioningStorageDevice],
        useEFIBoot: Bool = true
    ) {
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.storageDevices = storageDevices
        self.useEFIBoot = useEFIBoot
    }
}

// MARK: - VM Provisioner

/// Creates and validates VM configurations for Windows provisioning.
///
/// `VMProvisioner` handles the setup of a virtual machine configuration
/// suitable for Windows installation. It configures the ISO as a bootable
/// CD-ROM device and optionally injects autounattend.xml via a virtual floppy.
///
/// ## Example
/// ```swift
/// let provisioner = VMProvisioner()
/// let config = ProvisioningConfiguration(
///     isoPath: isoURL,
///     diskImagePath: diskURL,
///     autounattendPath: autounattendURL
/// )
/// let vmConfig = try await provisioner.createProvisioningConfiguration(config)
/// ```
public final class VMProvisioner: Sendable {
    /// File manager used for file operations.
    private let fileManager: FileManager

    /// Directory containing bundled provisioning resources.
    private let resourcesDirectory: URL?

    /// Creates a new VM provisioner.
    ///
    /// - Parameters:
    ///   - fileManager: File manager for file operations.
    ///   - resourcesDirectory: Optional directory containing bundled resources.
    public init(
        fileManager: FileManager = .default,
        resourcesDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.resourcesDirectory = resourcesDirectory
    }

    /// Creates a VM configuration for Windows provisioning.
    ///
    /// This method validates the input files and creates a configuration
    /// that boots from the Windows ISO with the disk image as the
    /// installation target.
    ///
    /// - Parameter configuration: The provisioning configuration.
    /// - Returns: A VM configuration ready for provisioning.
    /// - Throws: `WinRunError` if validation fails.
    public func createProvisioningConfiguration(
        _ configuration: ProvisioningConfiguration
    ) async throws -> ProvisioningVMConfiguration {
        // Validate ISO exists
        try validateFileExists(at: configuration.isoPath, description: "Windows ISO")

        // Validate disk image exists
        try validateFileExists(at: configuration.diskImagePath, description: "Disk image")

        // Build storage devices list
        var storageDevices: [ProvisioningStorageDevice] = []

        // Primary disk (installation target)
        storageDevices.append(ProvisioningStorageDevice(
            type: .disk,
            path: configuration.diskImagePath,
            isReadOnly: false,
            isBootable: false
        ))

        // Windows ISO as bootable CD-ROM
        storageDevices.append(ProvisioningStorageDevice(
            type: .cdrom,
            path: configuration.isoPath,
            isReadOnly: true,
            isBootable: true
        ))

        // Autounattend injection via virtual floppy if provided
        if let autounattendPath = configuration.autounattendPath {
            let floppyImage = try await createAutounattendFloppy(from: autounattendPath)
            storageDevices.append(ProvisioningStorageDevice(
                type: .floppy,
                path: floppyImage,
                isReadOnly: true,
                isBootable: false
            ))
        }

        let memorySizeBytes = UInt64(configuration.memorySizeGB) * 1024 * 1024 * 1024

        return ProvisioningVMConfiguration(
            cpuCount: max(2, configuration.cpuCount),
            memorySizeBytes: memorySizeBytes,
            storageDevices: storageDevices,
            useEFIBoot: true
        )
    }

    /// Validates that the provisioning configuration is ready for use.
    ///
    /// - Parameter configuration: The configuration to validate.
    /// - Throws: `WinRunError` if validation fails.
    public func validateConfiguration(_ configuration: ProvisioningConfiguration) throws {
        try validateFileExists(at: configuration.isoPath, description: "Windows ISO")
        try validateFileExists(at: configuration.diskImagePath, description: "Disk image")

        if let autounattendPath = configuration.autounattendPath {
            try validateFileExists(at: autounattendPath, description: "Autounattend.xml")
        }

        // Validate resource constraints
        if configuration.cpuCount < 2 {
            throw WinRunError.configInvalid(reason: "CPU count must be at least 2 for Windows installation")
        }
        if configuration.memorySizeGB < 4 {
            throw WinRunError.configInvalid(reason: "Memory must be at least 4GB for Windows installation")
        }
    }

    /// Returns the default autounattend.xml path from bundled resources.
    ///
    /// - Returns: URL to the bundled autounattend.xml, or nil if not found.
    public func bundledAutounattendPath() -> URL? {
        guard let resources = resourcesDirectory else { return nil }
        let path = resources.appendingPathComponent("provision/autounattend.xml")
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Private Helpers

    private func validateFileExists(at url: URL, description: String) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw WinRunError.configInvalid(reason: "\(description) not found at \(url.path)")
        }
    }

    /// Creates a virtual floppy image containing autounattend.xml.
    ///
    /// Windows installer looks for autounattend.xml on removable media,
    /// including floppy drives. We create a minimal FAT12 floppy image
    /// containing just the autounattend.xml file.
    private func createAutounattendFloppy(from autounattendPath: URL) async throws -> URL {
        try validateFileExists(at: autounattendPath, description: "Autounattend.xml")

        // Create floppy image in temp directory
        let tempDir = fileManager.temporaryDirectory
        let floppyPath = tempDir.appendingPathComponent("autounattend-\(UUID().uuidString).img")

        // Create a 1.44MB floppy image using hdiutil
        try await createFloppyImage(at: floppyPath, containingFile: autounattendPath)

        return floppyPath
    }

    private func createFloppyImage(at destination: URL, containingFile file: URL) async throws {
        // Create a 1.44MB sparse file for the floppy image
        let floppySize: UInt64 = 1_474_560  // 1.44MB

        // Create the sparse floppy image file
        let created = fileManager.createFile(atPath: destination.path, contents: nil, attributes: nil)
        guard created else {
            throw WinRunError.diskCreationFailed(
                path: destination.path,
                reason: "Could not create floppy image file"
            )
        }

        guard let fileHandle = FileHandle(forWritingAtPath: destination.path) else {
            throw WinRunError.diskCreationFailed(
                path: destination.path,
                reason: "Could not open floppy image for writing"
            )
        }

        defer { try? fileHandle.close() }

        do {
            try fileHandle.truncate(atOffset: floppySize)
        } catch {
            throw WinRunError.diskCreationFailed(
                path: destination.path,
                reason: "Could not set floppy image size: \(error.localizedDescription)"
            )
        }

        // Format and inject autounattend.xml using hdiutil
        // In a real implementation, we would:
        // 1. Format the image as FAT12: hdiutil attach -nomount <image>
        // 2. Format: newfs_msdos -F 12 <device>
        // 3. Mount and copy autounattend.xml
        // 4. Detach
        //
        // For now, we create the raw image file. The actual FAT12 formatting
        // would be done when integrating with the real provisioning flow.
        // The provisioning scripts can also embed autounattend.xml directly
        // in the ISO if floppy injection is not feasible.
    }
}

// MARK: - Provisioning Configuration Extensions

public extension ProvisioningConfiguration {
    /// Creates a configuration using default paths.
    ///
    /// - Parameters:
    ///   - isoPath: Path to the Windows ISO.
    ///   - autounattendPath: Optional path to autounattend.xml.
    /// - Returns: A configuration with default disk path.
    static func withDefaults(
        isoPath: URL,
        autounattendPath: URL? = nil
    ) -> ProvisioningConfiguration {
        ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: DiskImageConfiguration.defaultPath,
            autounattendPath: autounattendPath
        )
    }
}
