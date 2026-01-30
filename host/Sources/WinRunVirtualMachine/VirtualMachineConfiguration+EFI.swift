import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

// MARK: - EFI and Network Configuration Helpers

#if canImport(Virtualization)
/// Extension containing EFI and network configuration helpers.
@available(macOS 13, *)
extension VirtualMachineController {
    /// Gets or creates the EFI variable store for Windows boot persistence.
    ///
    /// The EFI variable store is required for Windows ARM64 to boot correctly.
    /// During installation, Windows Setup writes boot manager entries to NVRAM.
    /// These entries must persist across reboots for Windows to boot from disk.
    func getOrCreateEFIVariableStore(for config: VMConfiguration) throws -> VZEFIVariableStore {
        let efiVarsURL = config.disk.efiVariableStorePath

        // Create parent directory if needed
        let parentDir = efiVarsURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        // Check if variable store already exists
        if FileManager.default.fileExists(atPath: efiVarsURL.path) {
            return VZEFIVariableStore(url: efiVarsURL)
        }

        // Create new variable store
        return try VZEFIVariableStore(creatingVariableStoreAt: efiVarsURL)
    }

    /// Creates a network device attachment based on the configuration.
    func makeNetworkDeviceAttachment(for config: VMConfiguration) throws -> VZNetworkDeviceAttachment {
        switch config.network.mode {
        case .nat:
            return VZNATNetworkDeviceAttachment()
        case .bridged:
            guard let identifier = config.network.interfaceIdentifier else {
                throw VMConfigurationValidationError.bridgedInterfaceNotSpecified
            }
            guard let interface = VZBridgedNetworkInterface.networkInterfaces.first(where: {
                $0.identifier == identifier || $0.localizedDisplayName == identifier
            }) else {
                throw VMConfigurationValidationError.bridgedInterfaceUnavailable(identifier)
            }
            return VZBridgedNetworkDeviceAttachment(interface: interface)
        }
    }
}
#endif
