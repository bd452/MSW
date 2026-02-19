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

    /// Path to the VirtIO drivers ISO (virtio-win.iso).
    /// Required for graphics display during installation.
    public let virtioDriversPath: URL?

    /// CPU cores to allocate during installation.
    public let cpuCount: Int

    /// Memory in GB to allocate during installation.
    public let memorySizeGB: Int

    /// Default CPU count for provisioning.
    public static let defaultCPUCount = 4

    /// Default memory in GB for provisioning.
    public static let defaultMemorySizeGB = 8

    /// Creates a provisioning configuration.
    public init(
        isoPath: URL,
        diskImagePath: URL,
        autounattendPath: URL? = nil,
        virtioDriversPath: URL? = nil,
        cpuCount: Int = ProvisioningConfiguration.defaultCPUCount,
        memorySizeGB: Int = ProvisioningConfiguration.defaultMemorySizeGB
    ) {
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.autounattendPath = autounattendPath
        self.virtioDriversPath = virtioDriversPath
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
    }

    /// Creates a configuration using default paths.
    public static func withDefaults(
        isoPath: URL,
        autounattendPath: URL? = nil,
        virtioDriversPath: URL? = nil
    ) -> ProvisioningConfiguration {
        ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: DiskImageConfiguration.defaultPath,
            autounattendPath: autounattendPath,
            virtioDriversPath: virtioDriversPath
        )
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

    public let type: DeviceType
    public let path: URL
    public let isReadOnly: Bool
    public let isBootable: Bool

    public init(type: DeviceType, path: URL, isReadOnly: Bool = false, isBootable: Bool = false) {
        self.type = type
        self.path = path
        self.isReadOnly = isReadOnly
        self.isBootable = isBootable
    }
}

/// Complete VM configuration for Windows provisioning.
public struct ProvisioningVMConfiguration: Equatable, Sendable {
    public let cpuCount: Int
    public let memorySizeBytes: UInt64
    public let storageDevices: [ProvisioningStorageDevice]
    public let useEFIBoot: Bool
    public let efiVariableStorePath: URL?

    public var memorySizeGB: Int {
        Int(memorySizeBytes / (1024 * 1024 * 1024))
    }

    public init(
        cpuCount: Int,
        memorySizeBytes: UInt64,
        storageDevices: [ProvisioningStorageDevice],
        useEFIBoot: Bool = true,
        efiVariableStorePath: URL? = nil
    ) {
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.storageDevices = storageDevices
        self.useEFIBoot = useEFIBoot
        self.efiVariableStorePath = efiVariableStorePath
    }
}
