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

    /// Path to VirtIO drivers ISO (optional but recommended for performance).
    ///
    /// Download from: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
    /// The `install-drivers.ps1` script will search for and install these drivers.
    public let virtioDriversISOPath: URL?

    /// Path to WinRunAgent.msi installer (required for host-guest communication).
    ///
    /// Built from the `guest/WinRunAgent.Installer` project.
    /// If not provided, the agent installation will be skipped.
    public let agentInstallerPath: URL?

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
        virtioDriversISOPath: URL? = nil,
        agentInstallerPath: URL? = nil,
        cpuCount: Int = ProvisioningConfiguration.defaultCPUCount,
        memorySizeGB: Int = ProvisioningConfiguration.defaultMemorySizeGB
    ) {
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.autounattendPath = autounattendPath
        self.virtioDriversISOPath = virtioDriversISOPath
        self.agentInstallerPath = agentInstallerPath
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
    }

    /// Creates a configuration using default paths.
    public static func withDefaults(
        isoPath: URL,
        autounattendPath: URL? = nil,
        virtioDriversISOPath: URL? = nil,
        agentInstallerPath: URL? = nil
    ) -> ProvisioningConfiguration {
        ProvisioningConfiguration(
            isoPath: isoPath,
            diskImagePath: DiskImageConfiguration.defaultPath,
            autounattendPath: autounattendPath,
            virtioDriversISOPath: virtioDriversISOPath,
            agentInstallerPath: agentInstallerPath
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
public final class VMProvisioner: Sendable {
    private let resourcesDirectory: URL?
    private let floppyImageCreator: FloppyImageCreator
    private let installationTask = InstallationTaskHolder()

    public init(resourcesDirectory: URL? = nil) {
        self.resourcesDirectory = resourcesDirectory
        self.floppyImageCreator = FloppyImageCreator()
    }

    // MARK: - Configuration Creation

    /// Creates a VM configuration for Windows provisioning.
    public func createProvisioningConfiguration(
        _ configuration: ProvisioningConfiguration
    ) async throws -> ProvisioningVMConfiguration {
        try validateFileExists(at: configuration.isoPath, description: "Windows ISO")
        try validateFileExists(at: configuration.diskImagePath, description: "Disk image")

        var storageDevices: [ProvisioningStorageDevice] = []

        storageDevices.append(
            ProvisioningStorageDevice(
                type: .disk,
                path: configuration.diskImagePath,
                isReadOnly: false,
                isBootable: false
            ))

        storageDevices.append(
            ProvisioningStorageDevice(
                type: .cdrom,
                path: configuration.isoPath,
                isReadOnly: true,
                isBootable: true
            ))

        // Create autounattend media with optional agent installer
        if let autounattendPath = configuration.autounattendPath {
            let autounattendMedia = try await createAutounattendMedia(
                from: autounattendPath,
                agentInstallerPath: configuration.agentInstallerPath
            )

            // Mount as secondary CD-ROM - Windows Setup will scan all removable media
            // for autounattend.xml during installation
            storageDevices.append(
                ProvisioningStorageDevice(
                    type: .cdrom,
                    path: autounattendMedia,
                    isReadOnly: true,
                    isBootable: false
                ))
        }

        // Attach VirtIO drivers ISO if provided
        if let virtioPath = configuration.virtioDriversISOPath {
            if FileManager.default.fileExists(atPath: virtioPath.path) {
                storageDevices.append(
                    ProvisioningStorageDevice(
                        type: .cdrom,
                        path: virtioPath,
                        isReadOnly: true,
                        isBootable: false
                    ))
            }
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
    public func validateConfiguration(_ configuration: ProvisioningConfiguration) throws {
        try validateFileExists(at: configuration.isoPath, description: "Windows ISO")
        try validateFileExists(at: configuration.diskImagePath, description: "Disk image")

        if let autounattendPath = configuration.autounattendPath {
            try validateFileExists(at: autounattendPath, description: "Autounattend.xml")
        }

        if configuration.cpuCount < 2 {
            throw WinRunError.configInvalid(
                reason: "CPU count must be at least 2 for Windows installation")
        }
        if configuration.memorySizeGB < 4 {
            throw WinRunError.configInvalid(
                reason: "Memory must be at least 4GB for Windows installation")
        }
    }

    /// Returns the default autounattend.xml path from bundled resources.
    public func bundledAutounattendPath() -> URL? {
        guard let resources = resourcesDirectory else { return nil }
        let path = resources.appendingPathComponent("provision/autounattend.xml")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Installation Lifecycle

    /// Starts the Windows installation process.
    ///
    /// This method:
    /// 1. Validates the provisioning configuration
    /// 2. Creates the VM configuration with ISO and autounattend media
    /// 3. Boots the VM from the Windows ISO
    /// 4. Monitors installation progress
    /// 5. Shuts down the VM when complete
    ///
    /// - Parameters:
    ///   - configuration: The provisioning configuration with ISO and disk paths
    ///   - delegate: Optional delegate for progress updates
    /// - Returns: The installation result
    public func startInstallation(
        configuration: ProvisioningConfiguration,
        delegate: (any InstallationDelegate)? = nil
    ) async throws -> InstallationResult {
        let startTime = Date()

        // Validate configuration early, returning error result if invalid
        do {
            try validateConfiguration(configuration)
        } catch {
            return handleInstallationError(
                error,
                startTime: startTime,
                diskPath: configuration.diskImagePath,
                delegate: delegate
            )
        }

        let isCancelled = { @Sendable in self.installationTask.isCancelled }

        reportProgress(
            delegate, phase: .preparing, overall: 0, message: "Preparing Windows installation...")

        if isCancelled() {
            return createCancelledResult(
                startTime: startTime, diskPath: configuration.diskImagePath)
        }

        do {
            // Create VM configuration with all storage devices
            let vmConfiguration = try await createProvisioningConfiguration(configuration)

            reportProgress(
                delegate,
                phase: .booting,
                overall: 0.05,
                message: "Starting Windows Setup from ISO..."
            )

            if isCancelled() {
                return createCancelledResult(
                    startTime: startTime, diskPath: configuration.diskImagePath)
            }

            // Run the actual Windows installation
            try await runInstallationPhases(
                configuration: configuration,
                vmConfiguration: vmConfiguration,
                delegate: delegate,
                isCancelled: isCancelled
            )

            let diskUsage = try? getDiskUsage(at: configuration.diskImagePath)
            let result = InstallationResult(
                success: true,
                finalPhase: .complete,
                durationSeconds: Date().timeIntervalSince(startTime),
                diskImagePath: configuration.diskImagePath,
                diskUsageBytes: diskUsage
            )

            reportProgress(
                delegate, phase: .complete, overall: 1.0, message: "Windows installation completed")
            delegate?.installationDidComplete(with: result)

            return result
        } catch {
            return handleInstallationError(
                error,
                startTime: startTime,
                diskPath: configuration.diskImagePath,
                delegate: delegate
            )
        }
    }

    /// Cancels the current installation if one is in progress.
    public func cancelInstallation() {
        installationTask.cancel()

        // Also cancel the provisioning VM if running
        if let provisioningVM = currentProvisioningVM {
            Task {
                await provisioningVM.cancel()
            }
        }
    }

    /// Checks if an installation is currently in progress.
    public var isInstalling: Bool {
        installationTask.isRunning
    }

    // MARK: - Private Helpers

    private func validateFileExists(at url: URL, description: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WinRunError.configInvalid(reason: "\(description) not found at \(url.path)")
        }
    }

    /// Creates autounattend media (ISO preferred) for Windows unattended installation.
    ///
    /// This method creates an ISO image containing:
    /// - `autounattend.xml` - the unattended installation answer file
    /// - Provisioning scripts - PowerShell scripts for post-install configuration
    /// - WinRunAgent installer (if provided) - for host-guest communication
    ///
    /// ISO is preferred over floppy because FAT12 floppies only support 8.3 filenames,
    /// which would truncate `autounattend.xml` to `AUTOUNAT.XML`, breaking Windows Setup.
    private func createAutounattendMedia(
        from autounattendPath: URL,
        agentInstallerPath: URL? = nil
    ) async throws -> URL {
        try validateFileExists(at: autounattendPath, description: "Autounattend.xml")

        // Collect provisioning scripts if available in resources
        var provisionScripts: [URL] = []
        if let resources = resourcesDirectory {
            let provisionDir = resources.appendingPathComponent("provision")
            if FileManager.default.fileExists(atPath: provisionDir.path) {
                let scriptNames = [
                    "provision.ps1",
                    "install-drivers.ps1",
                    "install-agent.ps1",
                    "optimize-windows.ps1",
                    "finalize.ps1",
                ]
                for scriptName in scriptNames {
                    let scriptPath = provisionDir.appendingPathComponent(scriptName)
                    if FileManager.default.fileExists(atPath: scriptPath.path) {
                        provisionScripts.append(scriptPath)
                    }
                }
            }
        }

        // Add agent installer if provided
        if let agentPath = agentInstallerPath,
           FileManager.default.fileExists(atPath: agentPath.path) {
            provisionScripts.append(agentPath)
        }

        // Create ISO image with autounattend.xml and scripts (supports long filenames)
        return try floppyImageCreator.createAutounattendMedia(
            autounattendPath: autounattendPath,
            provisionScripts: provisionScripts,
            preferISO: true
        )
    }

    /// Legacy method for creating floppy image - deprecated, use createAutounattendMedia
    @available(*, deprecated, message: "Use createAutounattendMedia instead - floppy truncates filenames")
    private func createAutounattendFloppy(from autounattendPath: URL) async throws -> URL {
        try await createAutounattendMedia(from: autounattendPath)
    }

    private func reportProgress(
        _ delegate: (any InstallationDelegate)?,
        phase: InstallationPhase,
        overall: Double,
        message: String
    ) {
        let progress = InstallationProgress(
            phase: phase,
            phaseProgress: phase.isTerminal ? 1.0 : 0,
            overallProgress: overall,
            message: message
        )
        delegate?.installationDidUpdateProgress(progress)
    }

    private func runInstallationPhases(
        configuration: ProvisioningConfiguration,
        vmConfiguration: ProvisioningVMConfiguration,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        // Create and run the provisioning VM
        let provisioningVM = ProvisioningVirtualMachine(configuration: vmConfiguration)

        // Store reference for cancellation
        currentProvisioningVM = provisioningVM

        defer {
            currentProvisioningVM = nil
        }

        // Run installation with progress forwarding
        let success = try await provisioningVM.runInstallation { [weak delegate] progress in
            delegate?.installationDidUpdateProgress(progress)
        }

        if !success {
            throw WinRunError.internalError(message: "Windows installation did not complete successfully")
        }
    }

    /// Reference to the current provisioning VM (for cancellation)
    private var currentProvisioningVM: ProvisioningVirtualMachine?

    /// Runs a simulated installation (for testing or when Virtualization is unavailable).
    private func runSimulatedInstallationPhases(
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        let phases: [InstallationPhaseInfo] = [
            InstallationPhaseInfo(
                phase: .copyingFiles, weight: 0.30, message: "Copying Windows files..."),
            InstallationPhaseInfo(
                phase: .installingFeatures, weight: 0.25, message: "Installing features..."),
            InstallationPhaseInfo(
                phase: .firstBoot, weight: 0.20, message: "Completing first-time setup..."),
            InstallationPhaseInfo(
                phase: .postInstall, weight: 0.20, message: "Configuring Windows..."),
        ]

        var overallProgress = 0.05

        for phaseInfo in phases {
            if isCancelled() { throw WinRunError.cancelled }

            try await runSinglePhase(
                phaseInfo,
                baseProgress: overallProgress,
                delegate: delegate,
                isCancelled: isCancelled
            )
            overallProgress += phaseInfo.weight
        }
    }

    private func runSinglePhase(
        _ phaseInfo: InstallationPhaseInfo,
        baseProgress: Double,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        for step in 1...10 {
            if isCancelled() { throw WinRunError.cancelled }

            try await Task.sleep(nanoseconds: 10_000_000)

            let phaseProgress = Double(step) / 10.0
            let progress = InstallationProgress(
                phase: phaseInfo.phase,
                phaseProgress: phaseProgress,
                overallProgress: baseProgress + (phaseInfo.weight * phaseProgress),
                message: phaseInfo.message
            )
            delegate?.installationDidUpdateProgress(progress)
        }
    }

    private func createCancelledResult(startTime: Date, diskPath: URL) -> InstallationResult {
        InstallationResult(
            success: false,
            finalPhase: .cancelled,
            error: .cancelled,
            durationSeconds: Date().timeIntervalSince(startTime),
            diskImagePath: diskPath
        )
    }

    private func handleInstallationError(
        _ error: Error,
        startTime: Date,
        diskPath: URL,
        delegate: (any InstallationDelegate)?
    ) -> InstallationResult {
        let winRunError =
            (error as? WinRunError) ?? WinRunError.wrap(error, context: "Installation")
        let result = InstallationResult(
            success: false,
            finalPhase: .failed,
            error: winRunError,
            durationSeconds: Date().timeIntervalSince(startTime),
            diskImagePath: diskPath
        )

        reportProgress(
            delegate, phase: .failed, overall: 0, message: winRunError.localizedDescription)
        delegate?.installationDidComplete(with: result)

        return result
    }

    private func getDiskUsage(at url: URL) throws -> UInt64 {
        let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(resourceValues.totalFileAllocatedSize ?? 0)
    }
}
