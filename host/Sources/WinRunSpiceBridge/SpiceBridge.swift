import Foundation
import CoreGraphics
import WinRunShared

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

    public init(windowID: UInt64, title: String, frame: CGRect, isResizable: Bool) {
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.isResizable = isResizable
    }
}

public final class SpiceWindowStream {
    public weak var delegate: SpiceWindowStreamDelegate?
    private let logger: Logger
    private var timer: Timer?

    public init(logger: Logger = StandardLogger(subsystem: "SpiceWindowStream")) {
        self.logger = logger
    }

    public func connect(toWindowID windowID: UInt64) {
        logger.info("Connecting to Spice stream for window \(windowID)")
        // Placeholder implementation that simulates frames for development on non-macOS hosts.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let fakeFrame = Data(repeating: 0, count: 1024)
            self.delegate?.windowStream(self, didUpdateFrame: fakeFrame)
        }
    }

    public func disconnect() {
        timer?.invalidate()
        timer = nil
        delegate?.windowStreamDidClose(self)
    }
}
