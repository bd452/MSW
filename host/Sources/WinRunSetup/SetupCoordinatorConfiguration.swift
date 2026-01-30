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

    /// Path to VirtIO drivers ISO (optional but recommended).
    ///
    /// If provided, the ISO will be mounted during installation so that
    /// `install-drivers.ps1` can find and install the drivers.
    ///
    /// Download from: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
    public let virtioDriversISOPath: URL?

    /// Path to WinRunAgent.msi installer.
    ///
    /// If provided, the installer will be included on the autounattend ISO
    /// and installed by `install-agent.ps1`.
    public let agentInstallerPath: URL?

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
        virtioDriversISOPath: URL? = nil,
        agentInstallerPath: URL? = nil,
        cpuCount: Int = ProvisioningConfiguration.defaultCPUCount,
        memorySizeGB: Int = ProvisioningConfiguration.defaultMemorySizeGB
    ) {
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.diskSizeGB = diskSizeGB
        self.autounattendPath = autounattendPath
        self.virtioDriversISOPath = virtioDriversISOPath
        self.agentInstallerPath = agentInstallerPath
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
    }

    /// Converts to ProvisioningConfiguration for use with VMProvisioner.
    public func toProvisioningConfiguration() -> ProvisioningConfiguration {
        ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: diskImagePath,
            autounattendPath: autounattendPath,
            virtioDriversISOPath: virtioDriversISOPath,
            agentInstallerPath: agentInstallerPath,
            cpuCount: cpuCount,
            memorySizeGB: memorySizeGB
        )
    }
}
