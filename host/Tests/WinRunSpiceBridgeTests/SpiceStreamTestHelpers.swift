import CoreGraphics
import XCTest

@testable import WinRunShared
@testable import WinRunSpiceBridge

// MARK: - Test Transport

/// A controllable mock transport for testing SpiceWindowStream.
final class TestSpiceStreamTransport: SpiceStreamTransport {
    indirect enum OpenBehavior {
        case succeed
        case fail(SpiceStreamError)
        case delay(TimeInterval, then: OpenBehavior)
    }

    var openBehavior: OpenBehavior = .succeed
    var isOpen = false
    var openCallCount = 0
    var closeCallCount = 0
    var lastWindowID: UInt64?
    var lastConfiguration: SpiceStreamConfiguration?

    // Input tracking
    var mouseEvents: [MouseInputEvent] = []
    var keyboardEvents: [KeyboardInputEvent] = []
    var clipboardSent: [ClipboardData] = []
    var clipboardRequests: [ClipboardFormat] = []
    var dragDropEvents: [DragDropEvent] = []

    // Callback storage for triggering events from tests
    private var callbacks: SpiceStreamCallbacks?

    func openStream(
        configuration: SpiceStreamConfiguration,
        windowID: UInt64,
        callbacks: SpiceStreamCallbacks
    ) throws -> SpiceStreamSubscription {
        openCallCount += 1
        lastWindowID = windowID
        lastConfiguration = configuration
        self.callbacks = callbacks

        switch openBehavior {
        case .succeed:
            isOpen = true
            return SpiceStreamSubscription { [weak self] in
                self?.isOpen = false
            }
        case .fail(let error):
            throw error
        case .delay(let interval, let thenBehavior):
            // For testing async behavior
            Thread.sleep(forTimeInterval: interval)
            openBehavior = thenBehavior
            return try openStream(
                configuration: configuration, windowID: windowID, callbacks: callbacks)
        }
    }

    func closeStream(_ subscription: SpiceStreamSubscription) {
        closeCallCount += 1
        isOpen = false
        callbacks = nil
        subscription.cleanup()
    }

    func sendMouseEvent(_ event: MouseInputEvent) {
        mouseEvents.append(event)
    }

    func sendKeyboardEvent(_ event: KeyboardInputEvent) {
        keyboardEvents.append(event)
    }

    func sendClipboard(_ clipboard: ClipboardData) {
        clipboardSent.append(clipboard)
    }

    func requestClipboard(format: ClipboardFormat) {
        clipboardRequests.append(format)
    }

    func sendDragDropEvent(_ event: DragDropEvent) {
        dragDropEvents.append(event)
    }

    // Control channel
    var controlCallback: ((Data) -> Void)?
    var controlMessagesSent: [Data] = []

    func setControlCallback(_ callback: @escaping (Data) -> Void) {
        controlCallback = callback
    }

    func sendControlMessage(_ data: Data) -> Bool {
        controlMessagesSent.append(data)
        return true
    }

    func simulateControlMessage(_ data: Data) {
        controlCallback?(data)
    }

    // Test helpers to simulate events from guest

    func simulateFrame(_ data: Data) {
        callbacks?.onFrame(data)
    }

    func simulateMetadata(_ metadata: WindowMetadata) {
        callbacks?.onMetadata(metadata)
    }

    func simulateClose(_ reason: SpiceStreamCloseReason) {
        callbacks?.onClosed(reason)
    }

    func simulateClipboard(_ clipboard: ClipboardData) {
        callbacks?.onClipboard(clipboard)
    }

    func reset() {
        openBehavior = .succeed
        isOpen = false
        openCallCount = 0
        closeCallCount = 0
        lastWindowID = nil
        lastConfiguration = nil
        mouseEvents.removeAll()
        keyboardEvents.removeAll()
        clipboardSent.removeAll()
        clipboardRequests.removeAll()
        dragDropEvents.removeAll()
        controlMessagesSent.removeAll()
        controlCallback = nil
        callbacks = nil
    }
}

// MARK: - Test Delegate

final class TestSpiceWindowStreamDelegate: SpiceWindowStreamDelegate {
    var frames: [Data] = []
    var sharedFrames: [SharedFrame] = []
    var metadataUpdates: [WindowMetadata] = []
    var stateChanges: [SpiceConnectionState] = []
    var clipboardReceived: [ClipboardData] = []
    var didCloseCallCount = 0

    private let stateExpectation: XCTestExpectation?
    private let targetState: SpiceConnectionState?

    init(expectState: SpiceConnectionState? = nil, expectation: XCTestExpectation? = nil) {
        self.targetState = expectState
        self.stateExpectation = expectation
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateFrame frame: Data) {
        frames.append(frame)
    }

    func windowStream(_ stream: SpiceWindowStream, didReceiveSharedFrame frame: SharedFrame) {
        sharedFrames.append(frame)
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateMetadata metadata: WindowMetadata) {
        metadataUpdates.append(metadata)
    }

    func windowStream(_ stream: SpiceWindowStream, didChangeState state: SpiceConnectionState) {
        stateChanges.append(state)
        if let target = targetState, state == target {
            stateExpectation?.fulfill()
        }
    }

    func windowStreamDidClose(_ stream: SpiceWindowStream) {
        didCloseCallCount += 1
    }

    func windowStream(_ stream: SpiceWindowStream, didReceiveClipboard clipboard: ClipboardData) {
        clipboardReceived.append(clipboard)
    }

    func reset() {
        frames.removeAll()
        sharedFrames.removeAll()
        metadataUpdates.removeAll()
        stateChanges.removeAll()
        clipboardReceived.removeAll()
        didCloseCallCount = 0
    }
}

// MARK: - NullLogger

/// A logger that discards all messages (for use in tests).
struct NullLogger: Logger {
    func log(
        level: LogLevel,
        message: String,
        metadata: LogMetadata?,
        file: String,
        function: String,
        line: UInt
    ) {
        // Intentionally empty - discard all log messages
    }
}
