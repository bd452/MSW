import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

// MARK: - Vsock Communication Extension

extension VirtualMachineController {
    /// Creates a vsock connection to the guest on the specified port.
    /// - Parameter port: The port number to connect to
    /// - Returns: A file handle for bidirectional communication
    /// - Throws: VirtualMachineLifecycleError if VM not running or vsock unavailable
    public func connectVsock(port: UInt32) async throws -> FileHandle {
        guard state.status == .running else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("VM must be running to connect vsock")
        }

        #if canImport(Virtualization)
        guard #available(macOS 13, *) else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("macOS 13+ required for vsock")
        }

        guard let device = await getVsockDevice() else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("Vsock device not configured")
        }

        return try await withCheckedThrowingContinuation { continuation in
            device.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    continuation.resume(returning: connection.fileHandle)
                case .failure(let error):
                    continuation.resume(throwing: VirtualMachineLifecycleError.virtualizationUnavailable(
                        "Failed to connect to vsock port \(port): \(error.localizedDescription)"
                    ))
                }
            }
        }
        #else
        throw VirtualMachineLifecycleError.virtualizationUnavailable("Virtualization.framework not available")
        #endif
    }

    /// Listens for incoming vsock connections on the specified port.
    /// - Parameter port: The port number to listen on
    /// - Returns: An async sequence of incoming file handles
    public func listenVsock(port: UInt32) throws -> AsyncStream<FileHandle> {
        guard state.status == .running else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("VM must be running to listen on vsock")
        }

        #if canImport(Virtualization)
        guard #available(macOS 13, *) else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("macOS 13+ required for vsock")
        }

        return AsyncStream { continuation in
            Task {
                guard let device = await self.getVsockDevice() else {
                    continuation.finish()
                    return
                }

                let listener = device.setSocketListener(forPort: port) { _, _, connection in
                    continuation.yield(connection.fileHandle)
                    return true // Accept connection
                }

                continuation.onTermination = { _ in
                    device.removeSocketListener(forPort: port)
                }

                if !listener {
                    continuation.finish()
                }
            }
        }
        #else
        throw VirtualMachineLifecycleError.virtualizationUnavailable("Virtualization.framework not available")
        #endif
    }
}
