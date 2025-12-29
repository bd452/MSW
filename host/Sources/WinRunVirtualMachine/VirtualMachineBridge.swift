import Foundation
import WinRunShared
#if canImport(Virtualization)
import Virtualization
#endif

// MARK: - VM Delegate

#if canImport(Virtualization)
/// Delegate for handling VM lifecycle events from Virtualization.framework.
/// This class bridges VZVirtualMachineDelegate callbacks to the actor-isolated controller.
@available(macOS 13, *)
final class VirtualMachineDelegate: NSObject, VZVirtualMachineDelegate {
    private weak var controller: VirtualMachineController?
    private let logger: Logger

    init(controller: VirtualMachineController, logger: Logger) {
        self.controller = controller
        self.logger = logger
        super.init()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        logger.info("Guest VM stopped gracefully")
        Task { @MainActor in
            await controller?.handleGuestDidStop()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        logger.error("Guest VM stopped with error: \(error.localizedDescription)")
        Task { @MainActor in
            await controller?.handleGuestDidStopWithError(error)
        }
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        logger.warn("Network device disconnected: \(error.localizedDescription)")
    }
}
#endif

// MARK: - Native VM Bridge

#if canImport(Virtualization)
/// Provides async/await wrappers for VZVirtualMachine completion-handler APIs.
@available(macOS 13, *)
enum NativeVirtualMachineBridge {
    static func start(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    cont.resume(returning: ())
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func stop(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vm.stop { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    @available(macOS 14, *)
    static func pause(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vm.pause { result in
                switch result {
                case .success:
                    cont.resume(returning: ())
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    @available(macOS 14, *)
    static func resume(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vm.resume { result in
                switch result {
                case .success:
                    cont.resume(returning: ())
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func saveMachineState(_ vm: VZVirtualMachine, to url: URL) async throws {
        guard #available(macOS 14, *) else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable(
                "Saving VM state requires macOS 14.0 or later."
            )
        }

        // Pause the VM before saving state
        try await pause(vm)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vm.saveMachineStateTo(url: url) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    static func restoreMachineState(_ vm: VZVirtualMachine, from url: URL) async throws {
        guard #available(macOS 14, *) else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable(
                "Restoring VM state requires macOS 14.0 or later."
            )
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            vm.restoreMachineStateFrom(url: url) { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }

        // Resume the VM after restoring state
        try await resume(vm)
    }
}
#endif
