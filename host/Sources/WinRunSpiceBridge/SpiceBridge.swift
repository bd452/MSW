import Foundation
import CoreGraphics
import WinRunShared
#if os(macOS)
import CSpiceBridge
#endif

public protocol SpiceWindowStreamDelegate: AnyObject {
    func windowStream(_ stream: SpiceWindowStream, didUpdateFrame frame: Data)
    func windowStream(_ stream: SpiceWindowStream, didUpdateMetadata metadata: WindowMetadata)
    func windowStreamDidClose(_ stream: SpiceWindowStream)
}

public struct WindowMetadata: Codable, Hashable {
    public let windowID: UInt64
    public let title: String
    public let frame: CGRect
    public let isResizable: Bool
    public let scaleFactor: CGFloat

    public init(
        windowID: UInt64,
        title: String,
        frame: CGRect,
        isResizable: Bool,
        scaleFactor: CGFloat = 1.0
    ) {
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.isResizable = isResizable
        self.scaleFactor = scaleFactor
    }
}

public struct SpiceStreamConfiguration: Hashable {
    public enum Security {
        case plaintext
        case tls
    }

    public var host: String
    public var port: UInt16
    public var security: Security
    public var ticket: String?

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 5930,
        security: Security = .plaintext,
        ticket: String? = nil
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.ticket = ticket
    }

    public static var `default`: SpiceStreamConfiguration {
        SpiceStreamConfiguration()
    }
}

public final class SpiceWindowStream {
    public weak var delegate: SpiceWindowStreamDelegate?

    private let configuration: SpiceStreamConfiguration
    private let delegateQueue: DispatchQueue
    private let transport: SpiceStreamTransport
    private let logger: Logger
    private let stateQueue = DispatchQueue(label: "com.winrun.spice.window-stream.state")
    private var state = StreamState()
    private var reconnectPolicy: ReconnectPolicy
    private var reconnectWorkItem: DispatchWorkItem?
    private var metrics = SpiceStreamMetrics()

    public init(
        configuration: SpiceStreamConfiguration = .default,
        delegateQueue: DispatchQueue = .main,
        logger: Logger = StandardLogger(subsystem: "SpiceWindowStream"),
        transport: SpiceStreamTransport? = nil,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy()
    ) {
        self.configuration = configuration
        self.delegateQueue = delegateQueue
        self.logger = logger
        self.reconnectPolicy = reconnectPolicy
        #if os(macOS)
        self.transport = transport ?? LibSpiceStreamTransport(configuration: configuration, logger: logger)
        #else
        self.transport = transport ?? MockSpiceStreamTransport(logger: logger)
        #endif
    }

    public func connect(toWindowID windowID: UInt64) {
        stateQueue.async {
            guard self.state.lifecycle == .disconnected else {
                self.logger.debug("Ignoring duplicate connect for window \(windowID)")
                return
            }

            self.logger.info("Connecting to Spice stream for window \(windowID)")
            self.state.windowID = windowID
            self.state.isUserInitiatedClose = false
            self.state.lifecycle = .connecting
            self.metrics.lastErrorDescription = nil
            self.openStream(for: windowID)
        }
    }

    public func disconnect() {
        stateQueue.async {
            self.logger.info("Disconnect requested for window stream")
            self.state.isUserInitiatedClose = true
            self.cancelReconnect()
            guard let subscription = self.state.subscription else {
                self.finishDisconnect()
                return
            }

            self.transport.closeStream(subscription)
            self.state.subscription = nil
            self.finishDisconnect()
        }
    }

    public func metricsSnapshot() -> SpiceStreamMetrics {
        stateQueue.sync { metrics }
    }

    private func openStream(for windowID: UInt64) {
        let callbacks = SpiceStreamCallbacks(
            onFrame: { [weak self] data in
                self?.handleFrame(data)
            },
            onMetadata: { [weak self] metadata in
                self?.handleMetadata(metadata)
            },
            onClosed: { [weak self] reason in
                self?.handleClose(reason: reason)
            }
        )

        do {
            let subscription = try transport.openStream(
                configuration: configuration,
                windowID: windowID,
                callbacks: callbacks
            )
            state.subscription = subscription
            state.lifecycle = .connected
            reconnectWorkItem = nil
            metrics.reconnectAttempts = 0
            logger.info("Spice stream connected for window \(windowID)")
        } catch {
            metrics.lastErrorDescription = error.localizedDescription
            logger.error("Failed to connect Spice stream: \(error.localizedDescription)")
            scheduleReconnect(reason: SpiceStreamCloseReason(code: .transportError, message: error.localizedDescription))
        }
    }

    private func handleFrame(_ frame: Data) {
        stateQueue.async {
            self.metrics.framesReceived += 1
            guard let delegate = self.delegate else { return }
            self.delegateQueue.async { [weak self] in
                guard let self else { return }
                delegate.windowStream(self, didUpdateFrame: frame)
            }
        }
    }

    private func handleMetadata(_ metadata: WindowMetadata) {
        stateQueue.async {
            self.metrics.metadataUpdates += 1
            guard let delegate = self.delegate else { return }
            self.delegateQueue.async { [weak self] in
                guard let self else { return }
                delegate.windowStream(self, didUpdateMetadata: metadata)
            }
        }
    }

    private func handleClose(reason: SpiceStreamCloseReason) {
        stateQueue.async {
            self.logger.warn("Spice stream closed: \(reason)")
            let wasUserInitiated = self.state.isUserInitiatedClose
            self.state.subscription = nil

            switch reason.code {
            case .remoteClosed where !wasUserInitiated:
                self.finishDisconnect()
            case .transportError where !wasUserInitiated,
                 .authenticationFailed where !wasUserInitiated:
                self.scheduleReconnect(reason: reason)
            default:
                self.finishDisconnect()
            }
        }
    }

    private func scheduleReconnect(reason: SpiceStreamCloseReason) {
        guard let windowID = state.windowID else { return }
        metrics.reconnectAttempts += 1
        let attempt = metrics.reconnectAttempts
        let delay = reconnectPolicy.delay(for: attempt)
        state.lifecycle = .reconnecting

        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateQueue.async {
                guard !self.state.isUserInitiatedClose else { return }
                self.logger.info("Attempting Spice reconnect #\(attempt) for window \(windowID)")
                self.openStream(for: windowID)
            }
        }

        reconnectWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func finishDisconnect() {
        state.lifecycle = .disconnected
        cancelReconnect()
        delegateQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.windowStreamDidClose(self)
        }
    }
}

// MARK: - Internal Models

private struct StreamState {
    enum Lifecycle {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    var lifecycle: Lifecycle = .disconnected
    var subscription: SpiceStreamSubscription?
    var windowID: UInt64?
    var isUserInitiatedClose = false
}

public struct ReconnectPolicy {
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval

    public init(initialDelay: TimeInterval = 0.5, multiplier: Double = 1.8, maxDelay: TimeInterval = 15) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
    }

    func delay(for attempt: Int) -> TimeInterval {
        let exponent = pow(multiplier, Double(max(attempt - 1, 0)))
        return min(initialDelay * exponent, maxDelay)
    }
}

private struct SpiceStreamCloseReason: CustomStringConvertible {
    enum Code {
        case remoteClosed
        case transportError
        case authenticationFailed
    }

    let code: Code
    let message: String

    var description: String {
        "\(code) - \(message)"
    }
}

private struct SpiceStreamCallbacks {
    let onFrame: (Data) -> Void
    let onMetadata: (WindowMetadata) -> Void
    let onClosed: (SpiceStreamCloseReason) -> Void
}

private struct SpiceStreamSubscription {
    private let cleanupHandler: () -> Void

    init(cleanup: @escaping () -> Void) {
        cleanupHandler = cleanup
    }

    func cleanup() {
        cleanupHandler()
    }
}

private protocol SpiceStreamTransport {
    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription

    func closeStream(_ subscription: SpiceStreamSubscription)
}

#if os(macOS)
private enum SpiceStreamError: Error {
    case connectionFailed(String)
}

private final class LibSpiceStreamTransport: SpiceStreamTransport {
    private let configuration: SpiceStreamConfiguration
    private let logger: Logger

    init(configuration: SpiceStreamConfiguration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
    }

    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription {
        let trampoline = CallbackTrampoline(callbacks: callbacks)
        let unmanaged = Unmanaged.passRetained(trampoline)
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let handle: UnsafeMutablePointer<winrun_spice_stream>?
        if let ticket = configuration.ticket {
            handle = configuration.host.withCString { hostPointer in
                ticket.withCString { ticketPointer in
                    winrun_spice_stream_open(
                        hostPointer,
                        configuration.port,
                        configuration.security == .tls,
                        windowID,
                        unmanaged.toOpaque(),
                        spiceFrameThunk,
                        spiceMetadataThunk,
                        spiceClosedThunk,
                        ticketPointer,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
            }
        } else {
            handle = configuration.host.withCString { hostPointer in
                winrun_spice_stream_open(
                    hostPointer,
                    configuration.port,
                    configuration.security == .tls,
                    windowID,
                    unmanaged.toOpaque(),
                    spiceFrameThunk,
                    spiceMetadataThunk,
                    spiceClosedThunk,
                    nil,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
        }

        guard handle != nil else {
            unmanaged.release()
            let message = String(cString: errorBuffer)
            throw SpiceStreamError.connectionFailed(message.isEmpty ? "Unknown libspice error" : message)
        }

        return SpiceStreamSubscription {
            if let handle {
                winrun_spice_stream_close(handle)
            }
            unmanaged.release()
        }
    }

    func closeStream(_ subscription: SpiceStreamSubscription) {
        subscription.cleanup()
    }
}

private final class CallbackTrampoline {
    private let callbacks: SpiceStreamCallbacks

    init(callbacks: SpiceStreamCallbacks) {
        self.callbacks = callbacks
    }

    func handleFrame(_ data: Data) {
        callbacks.onFrame(data)
    }

    func handleMetadata(_ metadata: WindowMetadata) {
        callbacks.onMetadata(metadata)
    }

    func handleClose(_ reason: SpiceStreamCloseReason) {
        callbacks.onClosed(reason)
    }
}

private let spiceFrameThunk: @convention(c) (
    UnsafePointer<UInt8>?,
    Int,
    UnsafeMutableRawPointer?
) -> Void = { bytes, length, userData in
    guard let bytes, let userData else { return }
    let trampoline = Unmanaged<CallbackTrampoline>.fromOpaque(userData).takeUnretainedValue()
    let frame = Data(bytes: bytes, count: length)
    trampoline.handleFrame(frame)
}

private let spiceMetadataThunk: @convention(c) (
    UnsafePointer<winrun_spice_window_metadata>?,
    UnsafeMutableRawPointer?
) -> Void = { metadataPointer, userData in
    guard let metadataPointer, let userData else { return }
    let metadata = metadataPointer.pointee
    let title = metadata.title.flatMap { String(cString: $0) } ?? "Windows Application"
    let frame = CGRect(
        x: metadata.position_x,
        y: metadata.position_y,
        width: metadata.width,
        height: metadata.height
    )
    let windowMetadata = WindowMetadata(
        windowID: metadata.window_id,
        title: title,
        frame: frame,
        isResizable: metadata.is_resizable,
        scaleFactor: CGFloat(metadata.scale_factor)
    )
    let trampoline = Unmanaged<CallbackTrampoline>.fromOpaque(userData).takeUnretainedValue()
    trampoline.handleMetadata(windowMetadata)
}

private let spiceClosedThunk: @convention(c) (
    winrun_spice_close_reason,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { reason, messagePointer, userData in
    guard let userData else { return }
    let message = messagePointer.flatMap { String(cString: $0) } ?? ""
    let code: SpiceStreamCloseReason.Code
    switch reason {
    case WINRUN_SPICE_CLOSE_REASON_REMOTE:
        code = .remoteClosed
    case WINRUN_SPICE_CLOSE_REASON_AUTHENTICATION:
        code = .authenticationFailed
    default:
        code = .transportError
    }

    let trampoline = Unmanaged<CallbackTrampoline>.fromOpaque(userData).takeUnretainedValue()
    trampoline.handleClose(SpiceStreamCloseReason(code: code, message: message))
}
#else
private final class MockSpiceStreamTransport: SpiceStreamTransport {
    private final class TimerBox {
        var timer: DispatchSourceTimer?
    }

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription {
        logger.info("Mock Spice stream open for window \(windowID)")
        let box = TimerBox()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler {
            let fakeFrame = Data(repeating: UInt8.random(in: 0...255), count: 1024)
            callbacks.onFrame(fakeFrame)
            let metadata = WindowMetadata(
                windowID: windowID,
                title: "Mock Window \(windowID)",
                frame: CGRect(x: 100, y: 100, width: 800, height: 600),
                isResizable: true
            )
            callbacks.onMetadata(metadata)
        }
        timer.resume()
        box.timer = timer

        return SpiceStreamSubscription {
            box.timer?.cancel()
        }
    }

    func closeStream(_ subscription: SpiceStreamSubscription) {
        subscription.cleanup()
    }
}
#endif
