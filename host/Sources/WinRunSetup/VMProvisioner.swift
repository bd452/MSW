import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

// MARK: - VM Provisioner

/// Creates and validates VM configurations for Windows provisioning.
public final class VMProvisioner: Sendable {
    private let resourcesDirectory: URL?
    let logger: Logger
    private let floppyImageCreator: FloppyImageCreator
    private let isoModifier: ISOModifier
    private let installationTask = InstallationTaskHolder()

    public init(
        resourcesDirectory: URL? = nil,
        logger: Logger = StandardLogger(subsystem: "WinRunSetup.VMProvisioner", minimumLevel: .debug)
    ) {
        self.resourcesDirectory = resourcesDirectory
        self.logger = logger
        self.floppyImageCreator = FloppyImageCreator()
        self.isoModifier = ISOModifier(logger: logger)
    }

    // MARK: - Configuration Creation

    // swiftlint:disable function_body_length
    /// Creates a VM configuration for Windows provisioning.
    public func createProvisioningConfiguration(
        _ configuration: ProvisioningConfiguration
    ) async throws -> ProvisioningVMConfiguration {
        logger.info(
            "Creating provisioning VM configuration",
            metadata: [
                "isoPath": .string(configuration.isoPath.path),
                "diskImagePath": .string(configuration.diskImagePath.path),
                "hasAutounattend": .bool(configuration.autounattendPath != nil),
                "hasVirtioDrivers": .bool(configuration.virtioDriversPath != nil),
                "cpuCount": .int(configuration.cpuCount),
                "memoryGB": .int(configuration.memorySizeGB),
            ]
        )
        try validateFileExists(at: configuration.isoPath, description: "Windows ISO")
        try validateFileExists(at: configuration.diskImagePath, description: "Disk image")

        var storageDevices: [ProvisioningStorageDevice] = []

        // Add Windows installation ISO first so EFI boots installer media,
        // not the empty target disk.
        storageDevices.append(
            ProvisioningStorageDevice(
                type: .cdrom,
                path: configuration.isoPath,
                isReadOnly: true,
                isBootable: true
            ))

        storageDevices.append(
            ProvisioningStorageDevice(
                type: .disk,
                path: configuration.diskImagePath,
                isReadOnly: false,
                isBootable: false
            ))

        // Create autounattend ISO and mount as second CD-ROM if provided
        if let autounattendPath = configuration.autounattendPath {
            logger.info("Creating autounattend media", metadata: ["autounattendPath": .string(autounattendPath.path)])
            let autounattendISO = try await createAutounattendISO(from: autounattendPath)
            storageDevices.append(
                ProvisioningStorageDevice(
                    type: .cdrom,
                    path: autounattendISO,
                    isReadOnly: true,
                    isBootable: false
                ))
        }

        // Mount VirtIO drivers ISO if provided (required for graphics during installation)
        if let virtioPath = configuration.virtioDriversPath {
            try validateFileExists(at: virtioPath, description: "VirtIO drivers ISO")
            logger.info("Mounting VirtIO drivers ISO", metadata: ["virtioPath": .string(virtioPath.path)])
            storageDevices.append(
                ProvisioningStorageDevice(
                    type: .cdrom,
                    path: virtioPath,
                    isReadOnly: true,
                    isBootable: false
                ))
        }

        let memorySizeBytes = UInt64(configuration.memorySizeGB) * 1024 * 1024 * 1024
        let efiVariableStorePath = VMArtifactPaths.nvramPath(for: configuration.diskImagePath)
        let machineIdentifierPath = VMArtifactPaths.machineIdentifierPath(for: configuration.diskImagePath)
        try resetPersistedIdentityArtifacts(
            efiVariableStorePath: efiVariableStorePath,
            machineIdentifierPath: machineIdentifierPath
        )
        logger.debug(
            "Provisioning VM storage prepared",
            metadata: [
                "storageDeviceCount": .int(storageDevices.count),
                "efiVariableStorePath": .string(efiVariableStorePath.path),
                "machineIdentifierPath": .string(machineIdentifierPath.path),
            ]
        )

        return ProvisioningVMConfiguration(
            cpuCount: max(2, configuration.cpuCount),
            memorySizeBytes: memorySizeBytes,
            storageDevices: storageDevices,
            useEFIBoot: true,
            efiVariableStorePath: efiVariableStorePath,
            machineIdentifierPath: machineIdentifierPath
        )
    }
    // swiftlint:enable function_body_length

    /// Validates that the provisioning configuration is ready for use.
    public func validateConfiguration(_ configuration: ProvisioningConfiguration) throws {
        logger.debug("Validating provisioning configuration")
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
        let rootPath = resources.appendingPathComponent("autounattend.xml")
        if FileManager.default.fileExists(atPath: rootPath.path) {
            return rootPath
        }

        // Backward compatibility for layouts that place the file in Resources/provision.
        let provisionPath = resources
            .appendingPathComponent("provision")
            .appendingPathComponent("autounattend.xml")
        return FileManager.default.fileExists(atPath: provisionPath.path) ? provisionPath : nil
    }

    /// Returns the bundled VirtIO drivers ISO path if available.
    public func bundledVirtioDriversPath() -> URL? {
        guard let resources = resourcesDirectory else { return nil }
        let path = resources.appendingPathComponent("virtio-win.iso")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Returns the cached VirtIO drivers ISO path in Application Support.
    public func cachedVirtioDriversPath() -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let path = appSupport?.appendingPathComponent("WinRun/virtio-win.iso")
        guard let path else { return nil }
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Installation Lifecycle

    // swiftlint:disable function_body_length
    /// Starts the Windows installation process.
    public func startInstallation(
        configuration: ProvisioningConfiguration,
        delegate: (any InstallationDelegate)? = nil
    ) async throws -> InstallationResult {
        installationTask.start()
        defer { installationTask.stop() }

        let startTime = Date()
        logger.info(
            "Starting Windows installation",
            metadata: [
                "diskImagePath": .string(configuration.diskImagePath.path),
                "isoPath": .string(configuration.isoPath.path),
                "interactiveFallback": .bool(configuration.autounattendPath == nil),
            ]
        )

        // Validate configuration early, returning error result if invalid
        do {
            try validateConfiguration(configuration)
        } catch {
            logger.error("Installation configuration validation failed: \(error)")
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
            logger.warn("Installation cancelled before VM configuration")
            return createCancelledResult(
                startTime: startTime, diskPath: configuration.diskImagePath)
        }

        do {
            let vmConfig = try await createProvisioningConfiguration(configuration)
            logger.debug(
                "VM configuration created",
                metadata: [
                    "storageDevices": .int(vmConfig.storageDevices.count),
                    "cpuCount": .int(vmConfig.cpuCount),
                    "memoryGB": .int(vmConfig.memorySizeGB),
                ]
            )

            reportProgress(
                delegate,
                phase: .booting,
                overall: 0.05,
                message: "Starting Windows Setup from ISO..."
            )

            if isCancelled() {
                logger.warn("Installation cancelled before VM boot")
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
            logger.info(
                "Windows installation finished",
                metadata: [
                    "durationSeconds": .double(Date().timeIntervalSince(startTime)),
                    "diskUsageBytes": .int(Int(diskUsage ?? 0)),
                ]
            )
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
            logger.error("Windows installation failed with error: \(error)")
            return handleInstallationError(
                error,
                startTime: startTime,
                diskPath: configuration.diskImagePath,
                delegate: delegate
            )
        }
    }
    // swiftlint:enable function_body_length

    /// Cancels the current installation if one is in progress.
    public func cancelInstallation() {
        logger.warn("Cancel requested for active installation task")
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

    /// Creates an autounattend ISO with provisioning scripts and additional files.
    private func createAutounattendISO(from autounattendPath: URL) async throws -> URL {
        try validateFileExists(at: autounattendPath, description: "Autounattend.xml")

        // Collect provisioning assets from resources directory
        let (scripts, files) = collectProvisioningAssets()
        logger.debug(
            "Collected provisioning assets",
            metadata: [
                "scriptsCount": .int(scripts.count),
                "filesCount": .int(files.count),
            ]
        )

        // Create ISO with autounattend.xml, scripts, and additional files
        return try await isoModifier.createAutounattendISO(
            autounattendPath: autounattendPath,
            provisionScripts: scripts,
            additionalFiles: files
        )
    }

    /// Collects provisioning scripts and additional files from resources.
    private func collectProvisioningAssets() -> (scripts: [URL], files: [URL]) {
        var provisionScripts: [URL] = []
        var additionalFiles: [URL] = []

        guard let resources = resourcesDirectory else {
            logger.warn("No resources directory configured; provisioning assets unavailable")
            return ([], [])
        }

        // Collect provisioning scripts
        let provisionDir = resources.appendingPathComponent("provision")
        if FileManager.default.fileExists(atPath: provisionDir.path) {
            let scriptNames = [
                "provision.ps1", "install-drivers.ps1", "install-agent.ps1",
                "optimize-windows.ps1", "finalize.ps1",
            ]
            for scriptName in scriptNames {
                let scriptPath = provisionDir.appendingPathComponent(scriptName)
                if FileManager.default.fileExists(atPath: scriptPath.path) {
                    provisionScripts.append(scriptPath)
                }
            }
        }

        // Collect WinRunAgent.msi if available
        let msiPath = resources.appendingPathComponent("WinRunAgent.msi")
        if FileManager.default.fileExists(atPath: msiPath.path) {
            additionalFiles.append(msiPath)
        }

        logger.debug(
            "Provisioning assets resolution complete",
            metadata: [
                "resourcesDirectory": .string(resources.path),
                "scriptsCount": .int(provisionScripts.count),
                "filesCount": .int(additionalFiles.count),
            ]
        )
        return (provisionScripts, additionalFiles)
    }

    /// Clears persisted identity artifacts before a fresh install attempt.
    private func resetPersistedIdentityArtifacts(
        efiVariableStorePath: URL,
        machineIdentifierPath: URL
    ) throws {
        let fileManager = FileManager.default
        for path in [efiVariableStorePath, machineIdentifierPath] where fileManager.fileExists(atPath: path.path) {
            logger.info("Resetting persisted VM identity artifact", metadata: ["path": .string(path.path)])
            try fileManager.removeItem(at: path)
        }
    }

    /// Reports installation progress to the delegate.
    func reportProgress(
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
        logger.error(
            "Installation error",
            metadata: [
                "durationSeconds": .double(Date().timeIntervalSince(startTime)),
                "diskPath": .string(diskPath.path),
                "error": .string(winRunError.localizedDescription),
            ]
        )
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

    /// Gets disk usage at the given URL.
    func getDiskUsage(at url: URL) throws -> UInt64 {
        let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(resourceValues.totalFileAllocatedSize ?? 0)
    }
}
