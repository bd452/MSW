import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

// MARK: - Vsock Connection Wrapper

/// Wrapper for a vsock connection providing bidirectional communication.
public struct VsockConnection {
    /// File handle for reading from the connection
    public let readHandle: FileHandle
    /// File handle for writing to the connection
    public let writeHandle: FileHandle

    #if canImport(Virtualization)
    @available(macOS 13, *)
    init(connection: VZVirtioSocketConnection) {
        self.readHandle = connection.fileHandleForReading
        self.writeHandle = connection.fileHandleForWriting
    }
    #endif

    /// Initialize with explicit file handles (for testing)
    public init(readHandle: FileHandle, writeHandle: FileHandle) {
        self.readHandle = readHandle
        self.writeHandle = writeHandle
    }
}

// MARK: - Vsock Communication Extension

extension VirtualMachineController {
    /// Creates a vsock connection to the guest on the specified port.
    /// - Parameter port: The port number to connect to
    /// - Returns: A VsockConnection for bidirectional communication
    /// - Throws: VirtualMachineLifecycleError if VM not running or vsock unavailable
    public func connectVsock(port: UInt32) async throws -> VsockConnection {
        guard state.status == .running else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("VM must be running to connect vsock")
        }

        #if canImport(Virtualization)
        guard #available(macOS 13, *) else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("macOS 13+ required for vsock")
        }

        guard let device = getVsockDevice() else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("Vsock device not configured")
        }

        return try await withCheckedThrowingContinuation { continuation in
            device.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    continuation.resume(returning: VsockConnection(connection: connection))
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
}

#if canImport(Virtualization)
// MARK: - Vsock Listener

/// Listener for incoming vsock connections.
@available(macOS 13, *)
public final class VsockListener: NSObject, VZVirtioSocketListenerDelegate {
    private let onConnection: (VsockConnection) -> Bool
    private weak var device: VZVirtioSocketDevice?
    private let port: UInt32

    init(device: VZVirtioSocketDevice, port: UInt32, onConnection: @escaping (VsockConnection) -> Bool) {
        self.device = device
        self.port = port
        self.onConnection = onConnection
        super.init()
    }

    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let wrapper = VsockConnection(connection: connection)
        return onConnection(wrapper)
    }

    /// Stops listening and removes the listener from the device.
    public func stop() {
        device?.removeSocketListener(forPort: port)
    }
}

extension VirtualMachineController {
    /// Sets up a listener for incoming vsock connections on the specified port.
    /// - Parameters:
    ///   - port: The port number to listen on
    ///   - handler: Called for each incoming connection. Return true to accept.
    /// - Returns: A VsockListener that can be used to stop listening
    /// - Throws: VirtualMachineLifecycleError if VM not running or vsock unavailable
    @available(macOS 13, *)
    public func listenVsock(port: UInt32, handler: @escaping (VsockConnection) -> Bool) throws -> VsockListener {
        guard state.status == .running else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("VM must be running to listen on vsock")
        }

        guard let device = getVsockDevice() else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("Vsock device not configured")
        }

        let vsockListener = VsockListener(device: device, port: port, onConnection: handler)
        let listener = VZVirtioSocketListener()
        listener.delegate = vsockListener

        let success = device.setSocketListener(listener, forPort: port)
        if !success {
            throw VirtualMachineLifecycleError.virtualizationUnavailable("Failed to set vsock listener on port \(port)")
        }

        return vsockListener
    }
}
#endif
