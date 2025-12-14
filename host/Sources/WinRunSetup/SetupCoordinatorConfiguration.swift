import Foundation

// MARK: - Setup Coordinator Configuration

/// Configuration for the setup coordinator.
public struct SetupCoordinatorConfiguration: Sendable, Equatable {
    /// Path to the Windows ISO file.
    public let isoPath: URL

    /// Path where the disk image should be created.
    public let diskImagePath: URL

    /// Size of the disk image in GB.
    public let diskSizeGB: UInt64

    /// Path to autounattend.xml for unattended installation.
    public let autounattendPath: URL?

    /// CPU cores to allocate during installation.
    public let cpuCount: Int

    /// Memory in GB to allocate during installation.
    public let memorySizeGB: Int

    /// Creates a setup coordinator configuration.
    public init(
        isoPath: URL,
        diskImagePath: URL = DiskImageConfiguration.defaultPath,
        diskSizeGB: UInt64 = DiskImageConfiguration.defaultSizeGB,
        autounattendPath: URL? = nil,
        cpuCount: Int = ProvisioningConfiguration.defaultCPUCount,
        memorySizeGB: Int = ProvisioningConfiguration.defaultMemorySizeGB
    ) {
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.diskSizeGB = diskSizeGB
        self.autounattendPath = autounattendPath
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
    }
}
