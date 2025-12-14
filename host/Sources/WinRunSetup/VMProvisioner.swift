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
    private let fileManager: FileManager
    private let resourcesDirectory: URL?
    private let installationTask = InstallationTaskHolder()

    public init(
        fileManager: FileManager = .default,
        resourcesDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.resourcesDirectory = resourcesDirectory
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
        return fileManager.fileExists(atPath: path.path) ? path : nil
    }

    // MARK: - Installation Lifecycle

    /// Starts the Windows installation process.
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
                error, startTime: startTime, diskPath: configuration.diskImagePath,
                delegate: delegate)
        }

        let isCancelled = { @Sendable in self.installationTask.isCancelled }

        reportProgress(
            delegate, phase: .preparing, overall: 0, message: "Preparing Windows installation...")

        if isCancelled() {
            return createCancelledResult(
                startTime: startTime, diskPath: configuration.diskImagePath)
        }

        do {
            _ = try await createProvisioningConfiguration(configuration)

            reportProgress(
                delegate, phase: .booting, overall: 0.05,
                message: "Starting Windows Setup from ISO...")

            if isCancelled() {
                return createCancelledResult(
                    startTime: startTime, diskPath: configuration.diskImagePath)
            }

            try await runInstallationPhases(delegate: delegate, isCancelled: isCancelled)

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
                error, startTime: startTime, diskPath: configuration.diskImagePath,
                delegate: delegate)
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
        guard fileManager.fileExists(atPath: url.path) else {
            throw WinRunError.configInvalid(reason: "\(description) not found at \(url.path)")
        }
    }

    private func createAutounattendFloppy(from autounattendPath: URL) async throws -> URL {
        try validateFileExists(at: autounattendPath, description: "Autounattend.xml")

        let tempDir = fileManager.temporaryDirectory
        let floppyPath = tempDir.appendingPathComponent("autounattend-\(UUID().uuidString).img")
        let floppySize: UInt64 = 1_474_560

        let created = fileManager.createFile(
            atPath: floppyPath.path, contents: nil, attributes: nil)
        guard created else {
            throw WinRunError.diskCreationFailed(
                path: floppyPath.path, reason: "Could not create floppy image")
        }

        guard let fileHandle = FileHandle(forWritingAtPath: floppyPath.path) else {
            throw WinRunError.diskCreationFailed(
                path: floppyPath.path, reason: "Could not open floppy image")
        }

        defer { try? fileHandle.close() }

        do {
            try fileHandle.truncate(atOffset: floppySize)
        } catch {
            throw WinRunError.diskCreationFailed(
                path: floppyPath.path,
                reason: "Could not set floppy size: \(error.localizedDescription)"
            )
        }

        return floppyPath
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
                phaseInfo, baseProgress: overallProgress, delegate: delegate,
                isCancelled: isCancelled)
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
