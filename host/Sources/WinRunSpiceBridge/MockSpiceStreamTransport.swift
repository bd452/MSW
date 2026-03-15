import Foundation
import WinRunShared

#if !os(macOS)
// MARK: - Mock Implementation (non-macOS)

final class MockSpiceStreamTransport: SpiceStreamTransport {
    private final class TimerBox {
        var timer: DispatchSourceTimer?
    }

    private let logger: Logger
    private var mockControlCallback: ((Data) -> Void)?

    init(logger: Logger) {
        self.logger = logger
    }

    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription {
        logger.info(
            "Mock Spice stream open for window \(windowID) via \(configuration.transport.summaryDescription)"
        )
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

    func sendMouseEvent(_ event: MouseInputEvent) {
        logger.debug("Mock: sendMouseEvent type=\(event.eventType) at (\(event.x), \(event.y))")
    }

    func sendKeyboardEvent(_ event: KeyboardInputEvent) {
        logger.debug("Mock: sendKeyboardEvent type=\(event.eventType) keyCode=\(event.keyCode)")
    }

    func sendClipboard(_ clipboard: ClipboardData) {
        logger.debug("Mock: sendClipboard format=\(clipboard.format) size=\(clipboard.data.count)")
    }

    func requestClipboard(format: ClipboardFormat) {
        logger.debug("Mock: requestClipboard format=\(format)")
    }

    func sendDragDropEvent(_ event: DragDropEvent) {
        logger.debug("Mock: sendDragDropEvent type=\(event.eventType) files=\(event.files.count)")
    }

    func setControlCallback(_ callback: @escaping (Data) -> Void) {
        mockControlCallback = callback
        logger.debug("Mock: setControlCallback")
    }

    func sendControlMessage(_ data: Data) -> Bool {
        logger.debug("Mock: sendControlMessage size=\(data.count)")
        return true
    }

    /// Simulate receiving a control message (for testing)
    func simulateControlMessage(_ data: Data) {
        mockControlCallback?(data)
    }
}
#endif
