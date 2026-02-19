import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

// MARK: - VM Provisioner

/// Creates and validates VM configurations for Windows provisioning.
public final class VMProvisioner: Sendable {
    private let resourcesDirectory: URL?
    private let floppyImageCreator: FloppyImageCreator
    private let isoModifier: ISOModifier
    private let installationTask = InstallationTaskHolder()

    public init(resourcesDirectory: URL? = nil) {
        self.resourcesDirectory = resourcesDirectory
        self.floppyImageCreator = FloppyImageCreator()
        self.isoModifier = ISOModifier()
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

        // Add Windows installation ISO as first CD-ROM (bootable)
        storageDevices.append(
            ProvisioningStorageDevice(
                type: .cdrom,
                path: configuration.isoPath,
                isReadOnly: true,
                isBootable: true
            ))

        // Create autounattend ISO and mount as second CD-ROM if provided
        if let autounattendPath = configuration.autounattendPath {
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
            storageDevices.append(
                ProvisioningStorageDevice(
                    type: .cdrom,
                    path: virtioPath,
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

    /// Creates an autounattend ISO with provisioning scripts and additional files.
    private func createAutounattendISO(from autounattendPath: URL) async throws -> URL {
        try validateFileExists(at: autounattendPath, description: "Autounattend.xml")

        // Collect provisioning assets from resources directory
        let (scripts, files) = collectProvisioningAssets()

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

        return (provisionScripts, additionalFiles)
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
