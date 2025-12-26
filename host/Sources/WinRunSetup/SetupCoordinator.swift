import Foundation
import WinRunShared
import WinRunSpiceBridge

// MARK: - Setup Coordinator

/// Orchestrates the end-to-end Windows provisioning flow.
///
/// The coordinator manages:
/// 1. ISO validation (architecture, edition detection)
/// 2. Disk image creation
/// 3. Windows installation lifecycle
/// 4. Post-install provisioning (driver/agent installation, optimization)
/// 5. Golden snapshot creation
public actor SetupCoordinator {
    // MARK: - Dependencies

    private let isoValidator: ISOValidator
    private let diskCreator: DiskImageCreator
    private let vmProvisioner: VMProvisioner
    private let controlChannel: SpiceControlChannel?

    // MARK: - State

    private var currentState: ProvisioningState = .idle
    private var context: ProvisioningContext?
    private var isCancelled = false

    // Guest provisioning state (set via Spice message handlers)
    private var provisioningComplete = false
    private var provisioningError: WinRunError?

    // Stream for receiving guest provisioning messages
    private var guestMessageContinuation: AsyncStream<GuestProvisioningEvent>.Continuation?

    // MARK: - Delegate

    private weak var delegate: (any ProvisioningDelegate)?

    // MARK: - Initialization

    /// Creates a setup coordinator with default dependencies.
    public init(
        isoValidator: ISOValidator? = nil,
        diskCreator: DiskImageCreator? = nil,
        vmProvisioner: VMProvisioner? = nil,
        controlChannel: SpiceControlChannel? = nil
    ) {
        self.isoValidator = isoValidator ?? ISOValidator()
        self.diskCreator = diskCreator ?? DiskImageCreator()
        self.vmProvisioner = vmProvisioner ?? VMProvisioner()
        self.controlChannel = controlChannel
    }

    // MARK: - Public API

    /// Sets the delegate for receiving provisioning updates.
    public func setDelegate(_ delegate: (any ProvisioningDelegate)?) {
        self.delegate = delegate
    }

    /// Returns the current provisioning state.
    public var state: ProvisioningState {
        currentState
    }

    /// Returns whether provisioning is currently active.
    public var isProvisioning: Bool {
        currentState.phase.isActive
    }

    /// Starts the provisioning process with the given configuration.
    ///
    /// - Parameter configuration: The setup configuration.
    /// - Returns: The final provisioning result.
    @discardableResult
    public func startProvisioning(
        with configuration: SetupCoordinatorConfiguration
    ) async -> ProvisioningResult {
        guard canStartProvisioning else {
            return invalidStateResult(for: configuration)
        }

        let provisioningContext = initializeProvisioning(with: configuration)

        if let result = await runAllPhases(configuration: configuration, context: provisioningContext) {
            return result
        }

        // Success!
        let finalContext = context ?? provisioningContext
        transitionTo(.complete, message: "Setup complete")
        let result = ProvisioningResult.success(from: finalContext)
        delegate?.provisioningDidComplete(with: result)
        return result
    }

    private var canStartProvisioning: Bool {
        currentState.phase == .idle ||
            currentState.phase == .failed ||
            currentState.phase == .cancelled
    }

    private func invalidStateResult(for configuration: SetupCoordinatorConfiguration) -> ProvisioningResult {
        let error = WinRunError.configInvalid(
            reason: "Cannot start provisioning from state: \(currentState.phase.rawValue)"
        )
        return ProvisioningResult(
            success: false,
            finalPhase: currentState.phase,
            error: error,
            durationSeconds: 0,
            diskImagePath: configuration.diskImagePath
        )
    }

    private func initializeProvisioning(with configuration: SetupCoordinatorConfiguration) -> ProvisioningContext {
        isCancelled = false
        let provisioningContext = ProvisioningContext(
            isoPath: configuration.isoPath,
            diskImagePath: configuration.diskImagePath
        )
        context = provisioningContext
        return provisioningContext
    }

    /// Runs all provisioning phases. Returns a result if an error occurred, or nil on success.
    private func runAllPhases(
        configuration: SetupCoordinatorConfiguration,
        context: ProvisioningContext
    ) async -> ProvisioningResult? {
        // Phase 1: Validate ISO
        if let result = await executePhase(.validatingISO, "Validating Windows ISO...", context, operation: {
            try await self.validateISO(configuration: configuration)
        }) { return result }

        // Phase 2: Create disk image
        if let result = await executePhase(.creatingDisk, "Creating disk image...", context, operation: {
            try await self.createDiskImage(configuration: configuration)
        }) { return result }

        // Phase 3: Install Windows
        if let result = await executePhase(.installingWindows, "Installing Windows...", context, operation: {
            try await self.installWindows(configuration: configuration)
        }) { return result }

        // Phase 4: Post-install provisioning
        if let result = await executePhase(.postInstallProvisioning, "Configuring Windows...", context, operation: {
            try await self.runPostInstallProvisioning()
        }) { return result }

        // Phase 5: Create snapshot
        if let result = await executePhase(.creatingSnapshot, "Creating snapshot...", context, operation: {
            try await self.createSnapshot(configuration: configuration)
        }) { return result }

        return nil
    }

    /// Executes a single phase, returning a result if it failed or was cancelled.
    private func executePhase(
        _ phase: ProvisioningPhase,
        _ message: String,
        _ context: ProvisioningContext,
        operation: @escaping () async throws -> Void
    ) async -> ProvisioningResult? {
        do {
            try await runPhase(phase, message: message, operation: operation)
        } catch {
            return handleError(error, context: context)
        }

        if isCancelled {
            return handleCancellation(context: context)
        }

        return nil
    }

    /// Cancels the current provisioning operation.
    public func cancel() {
        guard currentState.phase.isActive else { return }
        isCancelled = true
        vmProvisioner.cancelInstallation()
    }

    /// Resets the coordinator to idle state for retry.
    public func reset() {
        guard currentState.phase.isTerminal else { return }
        transitionTo(.idle, message: "Ready to start")
        context = nil
        isCancelled = false
        provisioningComplete = false
        provisioningError = nil
    }

    // MARK: - Recovery State Accessors (for extension)

    /// Checks if rollback can be performed (failed/cancelled state).
    var canPerformRollback: Bool {
        currentState.phase == .failed || currentState.phase == .cancelled
    }

    /// Checks if rollback is available (failed/cancelled and disk exists).
    public var canRollback: Bool {
        canRetry && context.map { FileManager.default.fileExists(atPath: $0.diskImagePath.path) } ?? false
    }

    /// Checks if retry is available (failed or cancelled state).
    public var canRetry: Bool { currentState.phase == .failed || currentState.phase == .cancelled }

    /// Returns the last error if provisioning failed.
    public var lastError: WinRunError? { currentState.error }

    /// The current provisioning context (for extension).
    var provisioningContext: ProvisioningContext? { context }

    /// The current phase (for extension).
    var currentPhase: ProvisioningPhase { currentState.phase }

    /// Gets disk usage for rollback (for extension).
    func getDiskUsageForRollback(at url: URL) throws -> UInt64 {
        try getDiskUsage(at: url)
    }

    /// Deletes disk image for rollback (for extension).
    func deleteDiskImageForRollback(at url: URL) throws {
        try diskCreator.deleteDiskImage(at: url)
    }

    // MARK: - Phase Execution

    private func runPhase(
        _ phase: ProvisioningPhase,
        message: String,
        operation: @escaping () async throws -> Void
    ) async throws {
        transitionTo(phase, message: message)
        try await operation()
        updateProgress(phaseProgress: 1.0, message: "\(phase.displayName) complete")
    }

    // MARK: - Phase Implementations

    private func validateISO(configuration: SetupCoordinatorConfiguration) async throws {
        updateProgress(phaseProgress: 0.2, message: "Mounting ISO...")

        let validationResult = try await isoValidator.validate(isoURL: configuration.isoPath)

        updateProgress(phaseProgress: 0.8, message: "Checking Windows edition...")

        guard validationResult.isUsable else {
            let message =
                validationResult.editionInfo?.architecture ?? "Unknown"
            throw WinRunError.configInvalid(
                reason: "ISO is not ARM64 architecture (detected: \(message))"
            )
        }

        context?.isoValidation = validationResult
    }

    private func createDiskImage(configuration: SetupCoordinatorConfiguration) async throws {
        updateProgress(phaseProgress: 0.3, message: "Allocating disk space...")

        let diskConfig = DiskImageConfiguration(
            destinationURL: configuration.diskImagePath,
            sizeGB: configuration.diskSizeGB,
            overwriteExisting: false
        )

        let result = try await diskCreator.createDiskImage(configuration: diskConfig)

        context?.diskCreationResult = DiskCreationResult(
            path: result.path,
            requestedSizeBytes: result.sizeBytes,
            isSparse: result.isSparse
        )

        updateProgress(phaseProgress: 0.9, message: "Disk image created")
    }

    private func installWindows(configuration: SetupCoordinatorConfiguration) async throws {
        let provisionConfig = ProvisioningConfiguration(
            isoPath: configuration.isoPath,
            diskImagePath: configuration.diskImagePath,
            autounattendPath: configuration.autounattendPath,
            cpuCount: configuration.cpuCount,
            memorySizeGB: configuration.memorySizeGB
        )

        // Create an adapter delegate to forward installation progress
        let progressAdapter = InstallationProgressAdapter { [weak self] progress in
            guard let self else { return }
            Task {
                await self.handleInstallationProgress(progress)
            }
        }

        let result = try await vmProvisioner.startInstallation(
            configuration: provisionConfig,
            delegate: progressAdapter
        )

        if !result.success {
            if let error = result.error {
                throw error
            } else {
                throw WinRunError.internalError(
                    message: "Windows installation failed at phase: \(result.finalPhase.rawValue)"
                )
            }
        }

        context?.diskUsageBytes = result.diskUsageBytes
    }

    private func handleInstallationProgress(_ progress: InstallationProgress) {
        // Map installation progress (0.0-1.0) to the installingWindows phase weight
        let message = progress.message.isEmpty ? progress.phase.displayName : progress.message
        updateProgress(phaseProgress: progress.overallProgress, message: message)
    }

    private func runPostInstallProvisioning() async throws {
        // Post-install provisioning is driven by guest agent messages.
        // The guest sends ProvisionProgressMessage updates as it runs scripts.
        // This method waits for the ProvisionCompleteMessage or an unrecoverable error.

        updateProgress(phaseProgress: 0.0, message: "Waiting for guest agent...")

        // If we have a control channel, wait for real guest messages
        // Otherwise, use simulation for testing
        if controlChannel != nil {
            try await waitForGuestProvisioning()
        } else {
            try await simulateGuestProvisioning()
        }
    }

    /// Waits for guest provisioning messages via the Spice control channel.
    ///
    /// This creates an async stream and waits for provisioning events from the guest.
    /// The control channel delegate routes incoming messages to this stream.
    private func waitForGuestProvisioning() async throws {
        // Create stream for guest provisioning events
        let stream = AsyncStream<GuestProvisioningEvent> { continuation in
            self.guestMessageContinuation = continuation
        }

        defer {
            guestMessageContinuation?.finish()
            guestMessageContinuation = nil
        }

        try await waitForGuestProvisioningMessages(using: stream)
    }

    /// Helper to check cancellation state (called from extension).
    func checkCancelled() -> Bool {
        isCancelled
    }

    /// Simulates guest provisioning progress (used when no control channel is provided).
    ///
    /// This is useful for testing the coordinator without a live Spice connection.
    private func simulateGuestProvisioning() async throws {
        let phases: [(GuestProvisioningPhase, Double)] = [
            (.drivers, 0.25),
            (.agent, 0.50),
            (.optimize, 0.80),
            (.finalize, 0.95),
        ]

        for (phase, progress) in phases {
            if isCancelled { throw WinRunError.cancelled }

            let message = ProvisionProgressMessage(
                phase: phase,
                percent: UInt8(progress * 100),
                message: phase.displayName
            )
            handleProvisionProgress(message)
            try await Task.sleep(nanoseconds: 100_000_000)  // Simulate work
        }
    }

    // MARK: - Guest Message Handling

    /// Handles a provisioning progress message from the guest.
    ///
    /// Call this method when receiving `ProvisionProgressMessage` from the Spice channel.
    public func handleProvisionProgress(_ message: ProvisionProgressMessage) {
        guard currentState.phase == .postInstallProvisioning else { return }

        let overallProgress = mapGuestPhaseToProgress(message.phase, phaseProgress: message.progressFraction)
        updateProgress(phaseProgress: overallProgress, message: message.message)
    }

    /// Handles a provisioning error message from the guest.
    ///
    /// Call this method when receiving `ProvisionErrorMessage` from the Spice channel.
    /// - Returns: Whether provisioning should continue (if error is recoverable).
    @discardableResult
    public func handleProvisionError(_ message: ProvisionErrorMessage) -> Bool {
        guard currentState.phase == .postInstallProvisioning else { return false }

        let errorMessage = "[\(message.phase.rawValue)] \(message.message) (0x\(String(message.errorCode, radix: 16)))"

        if message.isRecoverable {
            // Log but continue - the guest will proceed
            updateProgress(
                phaseProgress: currentState.phaseProgress,
                message: "Warning: \(message.message)"
            )
            return true
        } else {
            // Unrecoverable error - provisioning failed
            provisioningError = WinRunError.internalError(message: errorMessage)
            return false
        }
    }

    /// Handles a provisioning complete message from the guest.
    ///
    /// Call this method when receiving `ProvisionCompleteMessage` from the Spice channel.
    public func handleProvisionComplete(_ message: ProvisionCompleteMessage) {
        guard currentState.phase == .postInstallProvisioning else { return }

        if message.success {
            // Update context with final info from guest
            context?.windowsVersion = message.windowsVersion
            context?.agentVersion = message.agentVersion
            context?.diskUsageBytes = message.diskUsageBytes
            updateProgress(phaseProgress: 1.0, message: "Guest provisioning complete")
            provisioningComplete = true
        } else {
            let errorMessage = message.errorMessage ?? "Guest provisioning failed"
            provisioningError = WinRunError.internalError(message: errorMessage)
        }
    }

    /// Maps a guest provisioning phase to overall post-install progress (0.0 to 1.0).
    private func mapGuestPhaseToProgress(_ phase: GuestProvisioningPhase, phaseProgress: Double) -> Double {
        calculateGuestPhaseProgress(phase, phaseProgress: phaseProgress)
    }

    private func createSnapshot(configuration: SetupCoordinatorConfiguration) async throws {
        updateProgress(phaseProgress: 0.3, message: "Shutting down VM...")
        try await Task.sleep(nanoseconds: 100_000_000)  // Placeholder

        if isCancelled { throw WinRunError.cancelled }

        updateProgress(phaseProgress: 0.7, message: "Creating golden snapshot...")
        try await Task.sleep(nanoseconds: 100_000_000)  // Placeholder

        // Update disk usage after snapshot
        if let fileSize = try? getDiskUsage(at: configuration.diskImagePath) {
            context?.diskUsageBytes = fileSize
        }
    }

    // MARK: - State Management

    private func transitionTo(_ phase: ProvisioningPhase, message: String, error: WinRunError? = nil) {
        let oldPhase = currentState.phase
        let result = ProvisioningStateTransition.transition(
            from: currentState,
            to: phase,
            message: message,
            error: error
        )

        switch result {
        case .success(let newState):
            currentState = newState
            notifyPhaseChange(from: oldPhase, to: phase)
            notifyProgress()
        case .failure:
            // Log but don't crash - this shouldn't happen with valid transitions
            break
        }
    }

    private func updateProgress(phaseProgress: Double, message: String) {
        currentState = ProvisioningState(
            phase: currentState.phase,
            phaseProgress: phaseProgress,
            message: message,
            error: currentState.error,
            enteredAt: currentState.enteredAt
        )
        notifyProgress()
    }

    // MARK: - Error Handling & Notifications

    private func handleError(_ error: Error, context: ProvisioningContext) -> ProvisioningResult {
        let winRunError = (error as? WinRunError) ?? WinRunError.wrap(error, context: "Provisioning")
        transitionTo(.failed, message: winRunError.localizedDescription, error: winRunError)
        let result = ProvisioningResult.failure(phase: currentState.phase, error: winRunError, context: context)
        delegate?.provisioningDidComplete(with: result)
        return result
    }

    private func handleCancellation(context: ProvisioningContext) -> ProvisioningResult {
        transitionTo(.cancelled, message: "Setup cancelled by user", error: .cancelled)
        let result = ProvisioningResult.cancelled(context: context)
        delegate?.provisioningDidComplete(with: result)
        return result
    }

    private func notifyProgress() {
        delegate?.provisioningDidUpdateProgress(ProvisioningProgress(from: currentState))
    }

    private func notifyPhaseChange(from oldPhase: ProvisioningPhase, to newPhase: ProvisioningPhase) {
        delegate?.provisioningDidChangePhase(from: oldPhase, to: newPhase)
    }

    // MARK: - Helpers

    private func getDiskUsage(at url: URL) throws -> UInt64 {
        let resourceValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(resourceValues.totalFileAllocatedSize ?? 0)
    }

    // MARK: - Control Channel Message Routing

    /// Routes a Spice message to the appropriate handler.
    ///
    /// Call this method from a `SpiceControlChannelDelegate` to route
    /// provisioning messages to this coordinator.
    ///
    /// - Parameters:
    ///   - message: The decoded message object.
    ///   - type: The Spice message type.
    public func routeSpiceMessage(_ message: Any, type: SpiceMessageType) {
        switch type {
        case .provisionProgress:
            if let msg = message as? ProvisionProgressMessage {
                guestMessageContinuation?.yield(.progress(msg))
            }
        case .provisionError:
            if let msg = message as? ProvisionErrorMessage {
                guestMessageContinuation?.yield(.error(msg))
            }
        case .provisionComplete:
            if let msg = message as? ProvisionCompleteMessage {
                guestMessageContinuation?.yield(.complete(msg))
            }
        default:
            // Ignore non-provisioning messages
            break
        }
    }

    /// Injects a provisioning progress message (for testing).
    ///
    /// This allows tests to simulate guest messages without a real Spice connection.
    public func injectProvisionProgress(_ message: ProvisionProgressMessage) {
        guestMessageContinuation?.yield(.progress(message))
    }

    /// Injects a provisioning error message (for testing).
    public func injectProvisionError(_ message: ProvisionErrorMessage) {
        guestMessageContinuation?.yield(.error(message))
    }

    /// Injects a provisioning complete message (for testing).
    public func injectProvisionComplete(_ message: ProvisionCompleteMessage) {
        guestMessageContinuation?.yield(.complete(message))
    }
}
