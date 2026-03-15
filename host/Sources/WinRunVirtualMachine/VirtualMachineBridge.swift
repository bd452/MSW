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
        logger.info("Guest VM stopped gracefully (state=\(virtualMachine.state.rawValue))")
        fputs("[VZ-DELEGATE] guestDidStop\n", stderr)
        Task { @MainActor in
            await controller?.handleGuestDidStop()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        logger.error("Guest VM stopped with error: \(error.localizedDescription)")
        fputs("[VZ-DELEGATE] didStopWithError: \(error)\n", stderr)
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
///
/// All VZ operations are dispatched to the main queue because `VZVirtualMachine`
/// requires operations on the queue where it was created. VMs must be created
/// via `createVM(_:delegate:)` to ensure consistency.
@available(macOS 13, *)
enum NativeVirtualMachineBridge {
    @MainActor
    static func createVM(
        _ config: VZVirtualMachineConfiguration,
        delegate: VZVirtualMachineDelegate?
    ) -> VZVirtualMachine {
        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = delegate
        return vm
    }

    static func start(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
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
    }

    /// Attempts a graceful shutdown via ACPI power button, falling back to
    /// force stop after the timeout expires.
    static func stop(_ vm: VZVirtualMachine, gracefulTimeout: TimeInterval = 30) async throws {
        let canRequest = await MainActor.run { vm.canRequestStop }
        if canRequest {
            do {
                try await MainActor.run { try vm.requestStop() }
            } catch {
                try await forceStop(vm)
                return
            }

            let deadline = Date().addingTimeInterval(gracefulTimeout)
            while Date() < deadline {
                let vmState = await MainActor.run { vm.state }
                if vmState == .stopped || vmState == .error {
                    return
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            let vmState = await MainActor.run { vm.state }
            if vmState != .stopped {
                try await forceStop(vm)
            }
        } else {
            try await forceStop(vm)
        }
    }

    static func forceStop(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.stop { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: ())
                    }
                }
            }
        }
    }

    @available(macOS 14, *)
    static func pause(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
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
    }

    @available(macOS 14, *)
    static func resume(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
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
    }

    static func saveMachineState(_ vm: VZVirtualMachine, to url: URL) async throws {
        guard #available(macOS 14, *) else {
            throw VirtualMachineLifecycleError.virtualizationUnavailable(
                "Saving VM state requires macOS 14.0 or later."
            )
        }

        try await pause(vm)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                vm.saveMachineStateTo(url: url) { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: ())
                    }
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
            DispatchQueue.main.async {
                vm.restoreMachineStateFrom(url: url) { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: ())
                    }
                }
            }
        }

        try await resume(vm)
    }
}
#endif
