import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

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

    /// Creates a configuration using default paths.
    public static func withDefaults(
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

        if let autounattendPath = configuration.autounattendPath {
            let floppyImage = try await createAutounattendFloppy(from: autounattendPath)
            storageDevices.append(
                ProvisioningStorageDevice(
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
    public func startInstallation(
        configuration: ProvisioningConfiguration,
        delegate: (any InstallationDelegate)? = nil
    ) async throws -> InstallationResult {
        installationTask.start()
        defer { installationTask.stop() }

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
            let vmConfig = try await createProvisioningConfiguration(configuration)

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

            try await runInstallationPhases(
                configuration: configuration,
                vmConfig: vmConfig,
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

    private func createAutounattendFloppy(from autounattendPath: URL) async throws -> URL {
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

        // Create the FAT12 floppy image with autounattend.xml and scripts
        return try floppyImageCreator.createAutounattendFloppy(
            autounattendPath: autounattendPath,
            provisionScripts: provisionScripts
        )
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
        vmConfig: ProvisioningVMConfiguration,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        #if canImport(Virtualization)
        if #available(macOS 13, *) {
            try await runInstallationPhasesWithVirtualization(
                configuration: configuration,
                vmConfig: vmConfig,
                delegate: delegate,
                isCancelled: isCancelled
            )
        } else {
            throw WinRunError.configInvalid(
                reason: "Windows installation requires macOS 13 or later")
        }
        #else
        throw WinRunError.configInvalid(
            reason: "Virtualization.framework is not available on this platform")
        #endif
    }

    #if canImport(Virtualization)
    @available(macOS 13, *)
    private func runInstallationPhasesWithVirtualization(
        configuration: ProvisioningConfiguration,
        vmConfig: ProvisioningVMConfiguration,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        // Convert ProvisioningVMConfiguration to VZVirtualMachineConfiguration
        // This may fail if disk images are invalid (e.g., in unit tests with fake files)
        let vzConfig: VZVirtualMachineConfiguration
        do {
            vzConfig = try buildVZConfiguration(from: vmConfig)
        } catch {
            // Re-throw as WinRunError for consistent error handling
            if let winRunError = error as? WinRunError {
                throw winRunError
            }
            throw WinRunError.configInvalid(
                reason: "Failed to create VM configuration: \(error.localizedDescription)")
        }

        // Validate configuration before creating VM
        do {
            try vzConfig.validate()
        } catch {
            throw WinRunError.configInvalid(
                reason: "VM configuration validation failed: \(error.localizedDescription)")
        }

        // Create the VM
        // Note: VZVirtualMachine initializer doesn't throw, but validation may have caught issues
        let vm = VZVirtualMachine(configuration: vzConfig)

        // Track initial disk usage
        let initialDiskUsage = try? getDiskUsage(at: configuration.diskImagePath)
        let minimumExpectedDiskUsage: UInt64 = 2 * 1024 * 1024 * 1024 // 2GB minimum for Windows

        // Start the VM
        reportProgress(
            delegate,
            phase: .copyingFiles,
            overall: 0.10,
            message: "Booting Windows Setup..."
        )

            if isCancelled() { throw WinRunError.cancelled }

        // Set up VM delegate to monitor state changes
        let vmDelegate = InstallationVMDelegate(
            onStateChange: { [weak self] state in
                guard let self else { return }
                // Update progress based on VM state
                if state == .running {
                    self.reportProgress(
                        delegate,
                        phase: .copyingFiles,
                        overall: 0.15,
                        message: "Windows Setup is running..."
                    )
                } else if state == .stopped {
                    self.reportProgress(
                        delegate,
                        phase: .firstBoot,
                        overall: 0.80,
                        message: "Windows installation completed, preparing first boot..."
                    )
                }
            }
        )
        vm.delegate = vmDelegate

        // Start the VM (this may fail if disk images are invalid)
        do {
            try await vm.start()
        } catch {
            throw WinRunError.internalError(
                message: "Failed to start VM: \(error.localizedDescription)")
        }

        reportProgress(
            delegate,
            phase: .copyingFiles,
            overall: 0.20,
            message: "Windows Setup is copying files..."
        )

        // Monitor installation progress by watching disk usage
        try await monitorInstallationProgress(
            vm: vm,
            configuration: configuration,
            initialDiskUsage: initialDiskUsage,
            minimumExpectedDiskUsage: minimumExpectedDiskUsage,
            delegate: delegate,
            isCancelled: isCancelled
        )

        // Installation phase complete
        reportProgress(
            delegate,
            phase: .postInstall,
            overall: 0.90,
            message: "Windows installation completed, ready for provisioning"
        )
    }

    @available(macOS 13, *)
    private func monitorInstallationProgress(
        vm: VZVirtualMachine,
        configuration: ProvisioningConfiguration,
        initialDiskUsage: UInt64?,
        minimumExpectedDiskUsage: UInt64,
        delegate: (any InstallationDelegate)?,
        isCancelled: @Sendable () -> Bool
    ) async throws {
        var lastDiskUsage = initialDiskUsage ?? 0
        var lastProgressUpdate = Date()
        let progressUpdateInterval: TimeInterval = 5.0 // Update every 5 seconds
        let maxInstallationTime: TimeInterval = 3600 // 1 hour max
        let installationStartTime = Date()

        while true {
            if isCancelled() {
                try? await vm.stop()
                throw WinRunError.cancelled
            }

            // Check for timeout
            let elapsed = Date().timeIntervalSince(installationStartTime)
            if elapsed > maxInstallationTime {
                try? await vm.stop()
                throw WinRunError.internalError(
                    message: "Windows installation timed out after \(Int(maxInstallationTime)) seconds")
            }

            // Check current disk usage
            let currentDiskUsage = try? getDiskUsage(at: configuration.diskImagePath)
            let vmState = vm.state

            // Update progress based on disk usage growth
            if let currentUsage = currentDiskUsage, currentUsage > lastDiskUsage {
                lastDiskUsage = currentUsage
                updateProgressFromDiskUsage(
                    currentUsage: currentUsage,
                    delegate: delegate
                )
            }

            // Check if installation is complete
            if try await checkInstallationComplete(
                vmState: vmState,
                vm: vm,
                configuration: configuration,
                initialDiskUsage: initialDiskUsage,
                minimumExpectedDiskUsage: minimumExpectedDiskUsage,
                delegate: delegate
            ) {
                break
            }

            // Update progress periodically even if disk usage hasn't changed
            if Date().timeIntervalSince(lastProgressUpdate) >= progressUpdateInterval {
                updatePeriodicProgress(
                    currentDiskUsage: currentDiskUsage,
                    delegate: delegate
                )
                lastProgressUpdate = Date()
            }

            // Sleep before next check
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        }
    }

    @available(macOS 13, *)
    private func updateProgressFromDiskUsage(
        currentUsage: UInt64,
        delegate: (any InstallationDelegate)?
    ) {
        // Estimate progress: 0.2 (booting) to 0.7 (installation complete)
        // Assume installation uses ~15GB, so map 0-15GB to 0.2-0.7 progress
        let estimatedGB = Double(currentUsage) / (1024 * 1024 * 1024)
        let installationProgress = min(0.7, 0.2 + (estimatedGB / 15.0) * 0.5)

        // Determine phase based on disk usage
        let phase: InstallationPhase
        let message: String
        if estimatedGB < 2 {
            phase = .copyingFiles
            message = "Copying Windows files..."
        } else if estimatedGB < 8 {
            phase = .installingFeatures
            message = "Installing Windows features..."
        } else {
            phase = .firstBoot
            message = "Completing installation..."
        }

        reportProgress(
            delegate,
            phase: phase,
            overall: installationProgress,
            message: message
        )
    }

    @available(macOS 13, *)
    private func checkInstallationComplete(
        vmState: VZVirtualMachine.State,
        vm: VZVirtualMachine,
        configuration: ProvisioningConfiguration,
        initialDiskUsage: UInt64?,
        minimumExpectedDiskUsage: UInt64,
        delegate: (any InstallationDelegate)?
    ) async throws -> Bool {
        // Installation is complete when:
        // 1. VM has stopped (Windows Setup completed and shut down)
        // 2. Disk usage has grown significantly (Windows is installed)
        guard vmState == .stopped else { return false }

        let finalDiskUsage = try? getDiskUsage(at: configuration.diskImagePath)
        if let finalUsage = finalDiskUsage,
           finalUsage >= minimumExpectedDiskUsage {
            // Installation appears complete
            reportProgress(
                delegate,
                phase: .firstBoot,
                overall: 0.85,
                message: "Windows installation completed successfully"
            )
            return true
        } else if let finalUsage = finalDiskUsage,
                  finalUsage > (initialDiskUsage ?? 0) {
            // Some installation occurred but may not be complete
            // Wait a bit more to see if VM restarts
            try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            if vm.state == .stopped {
                // Still stopped, assume installation complete
                return true
            }
        }
        return false
    }

    @available(macOS 13, *)
    private func updatePeriodicProgress(
        currentDiskUsage: UInt64?,
        delegate: (any InstallationDelegate)?
    ) {
        if let currentUsage = currentDiskUsage {
            let estimatedGB = Double(currentUsage) / (1024 * 1024 * 1024)
            let message = "Installing Windows... (\(String(format: "%.1f", estimatedGB)) GB used)"
            reportProgress(
                delegate,
                phase: .installingFeatures,
                overall: 0.50,
                message: message
            )
        }
    }

    @available(macOS 13, *)
    private func buildVZConfiguration(from vmConfig: ProvisioningVMConfiguration) throws -> VZVirtualMachineConfiguration {
        let vzConfig = VZVirtualMachineConfiguration()

        // CPU and memory
        vzConfig.cpuCount = vmConfig.cpuCount
        vzConfig.memorySize = vmConfig.memorySizeBytes

        // Platform
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VZGenericMachineIdentifier()
        vzConfig.platform = platform

        // Boot loader
        if vmConfig.useEFIBoot {
            vzConfig.bootLoader = VZEFIBootLoader()
        } else {
            throw WinRunError.configInvalid(
                reason: "Windows installation requires EFI boot")
        }

        // Storage devices
        var storageDevices: [VZStorageDeviceConfiguration] = []
        for device in vmConfig.storageDevices {
            switch device.type {
            case .disk:
                do {
                    let attachment = try VZDiskImageStorageDeviceAttachment(
                        url: device.path,
                        readOnly: device.isReadOnly
                    )
                    let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                    storageDevices.append(blockDevice)
                } catch {
                    throw WinRunError.configInvalid(
                        reason: "Invalid disk image at \(device.path.path): \(error.localizedDescription)")
                }

            case .cdrom:
                do {
                    let attachment = try VZDiskImageStorageDeviceAttachment(
                        url: device.path,
                        readOnly: true
                    )
                    let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                    storageDevices.append(blockDevice)
                } catch {
                    throw WinRunError.configInvalid(
                        reason: "Invalid ISO image at \(device.path.path): \(error.localizedDescription)")
                }

            case .floppy:
                // Virtualization.framework doesn't support floppy drives directly
                // Autounattend.xml should be injected via ISO or other means
                // For now, skip floppy devices
                break
            }
        }
        vzConfig.storageDevices = storageDevices

        // Network (minimal for installation)
        let networkAttachment = VZNATNetworkDeviceAttachment()
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = networkAttachment
        vzConfig.networkDevices = [networkDevice]

        // Graphics (minimal for installation)
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1024, heightInPixels: 768)]
        vzConfig.graphicsDevices = [graphics]

        // Input devices
        vzConfig.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        vzConfig.keyboards = [VZUSBKeyboardConfiguration()]

        // Other devices
        vzConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Validate configuration
        try vzConfig.validate()

        return vzConfig
    }

    // Helper class to monitor VM state during installation
    @available(macOS 13, *)
    private class InstallationVMDelegate: NSObject, VZVirtualMachineDelegate {
        let onStateChange: (VZVirtualMachine.State) -> Void

        init(onStateChange: @escaping (VZVirtualMachine.State) -> Void) {
            self.onStateChange = onStateChange
        }

        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            onStateChange(.stopped)
        }

        func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            onStateChange(.stopped)
        }

        func virtualMachine(
            _ virtualMachine: VZVirtualMachine,
            networkDevice: VZNetworkDevice,
            attachmentWasDisconnectedWithError error: Error
        ) {
            // Ignore network errors during installation
        }
    }
    #endif

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
