import Foundation
import AppKit
import WinRunShared
import WinRunSpiceBridge

/// Manages a window that displays content from a Windows guest application.
///
/// `WinRunWindowController` coordinates:
/// - NSWindow lifecycle and delegate handling
/// - Metal rendering via `MetalContentView`
/// - Spice stream connection and frame delivery
/// - Input event forwarding (mouse, keyboard, drag/drop)
/// - Clipboard synchronization
@available(macOS 13, *)
final class WinRunWindowController: NSObject, SpiceWindowStreamDelegate, MetalContentViewInputDelegate {
    private var window: NSWindow?
    private let renderer: SpiceFrameRenderer
    private var metalContentView: MetalContentView?
    private let stream: SpiceWindowStream
    private let logger: Logger

    /// Current metadata from the Spice stream
    private var currentMetadata: WindowMetadata?

    /// Clipboard synchronization
    private let clipboardManager: ClipboardManager

    override init() {
        self.logger = StandardLogger(subsystem: "WinRunWindowController")
        self.stream = SpiceWindowStream(configuration: SpiceStreamConfiguration.environmentDefault())
        self.renderer = SpiceFrameRenderer()
        self.clipboardManager = ClipboardManager()
        super.init()
        stream.delegate = self
        clipboardManager.delegate = self
    }

    func presentWindow(title: String) {
        let contentRect = NSRect(x: 100, y: 100, width: 800, height: 600)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 320, height: 240)
        window.delegate = self

        // Create Metal content view for GPU-accelerated frame rendering
        let metalView = MetalContentView(frame: contentRect, renderer: renderer)
        metalView.inputDelegate = self
        window.contentView = metalView
        self.metalContentView = metalView

        // Make window accept mouse moved events
        window.acceptsMouseMovedEvents = true

        // Center window on screen
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Start clipboard monitoring
        clipboardManager.startMonitoring()

        logger.info("Window created with Metal rendering layer and input forwarding")
        stream.connect(toWindowID: 0)
    }

    // MARK: - MetalContentViewInputDelegate

    func metalContentView(_ view: MetalContentView, didReceiveMouseEvent event: MouseInputEvent) {
        stream.sendMouseEvent(event)
    }

    func metalContentView(_ view: MetalContentView, didReceiveKeyboardEvent event: KeyboardInputEvent) {
        stream.sendKeyboardEvent(event)
    }

    func metalContentView(_ view: MetalContentView, didReceiveDragDropEvent event: DragDropEvent) {
        stream.sendDragDropEvent(event)
    }

    func metalContentViewDidRequestRetry(_ view: MetalContentView) {
        logger.info("User requested connection retry")
        stream.reconnect()
    }

    // MARK: - SpiceWindowStreamDelegate

    func windowStream(_ stream: SpiceWindowStream, didUpdateFrame frame: Data) {
        guard let metalView = metalContentView else { return }

        // Use metadata dimensions if available, otherwise estimate from frame size
        let width: Int
        let height: Int
        let scaleFactor: CGFloat

        if let metadata = currentMetadata {
            width = Int(metadata.frame.width)
            height = Int(metadata.frame.height)
            scaleFactor = metadata.scaleFactor
        } else {
            // Estimate dimensions assuming BGRA (4 bytes per pixel) and 16:9 aspect ratio
            let pixelCount = frame.count / 4
            let estimatedWidth = Int(sqrt(Double(pixelCount) * 16.0 / 9.0))
            width = estimatedWidth
            height = pixelCount / max(estimatedWidth, 1)
            scaleFactor = 1.0
        }

        metalView.updateFrame(
            pixelData: frame,
            width: width,
            height: height,
            guestScaleFactor: scaleFactor
        )
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateMetadata metadata: WindowMetadata) {
        currentMetadata = metadata

        guard let window = window else { return }

        // Update window title
        window.title = metadata.title

        // Optionally resize window to match guest frame size (scaled for Retina)
        if metadata.frame.width > 0 && metadata.frame.height > 0 {
            let backingScale = window.backingScaleFactor
            let pointWidth = metadata.frame.width / backingScale
            let pointHeight = metadata.frame.height / backingScale

            // Only resize if dimensions changed significantly
            let currentSize = window.contentView?.frame.size ?? .zero
            let widthDelta = abs(currentSize.width - pointWidth)
            let heightDelta = abs(currentSize.height - pointHeight)

            if widthDelta > 10 || heightDelta > 10 {
                let newContentSize = NSSize(width: pointWidth, height: pointHeight)
                window.setContentSize(newContentSize)
                logger.debug("Resized window to \(Int(pointWidth))x\(Int(pointHeight)) points")
            }
        }

        // Update resizable style based on metadata
        if metadata.isResizable {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
    }

    func windowStream(_ stream: SpiceWindowStream, didChangeState state: SpiceConnectionState) {
        logger.debug("Spice stream state changed: \(state)")
        metalContentView?.updateConnectionState(state)
    }

    func windowStreamDidClose(_ stream: SpiceWindowStream) {
        logger.info("Spice stream closed, closing window")
        clipboardManager.stopMonitoring()
        window?.close()
        metalContentView?.clearFrame()
    }

    func windowStream(_ stream: SpiceWindowStream, didReceiveClipboard clipboard: ClipboardData) {
        // Update macOS pasteboard with clipboard data from Windows guest
        clipboardManager.setFromGuest(clipboard)
    }
}

// MARK: - NSWindowDelegate

@available(macOS 13, *)
extension WinRunWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Disconnect the stream when window is closed by user
        clipboardManager.stopMonitoring()
        stream.disconnect()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        // Handle display changes (e.g., moving between Retina and non-Retina displays)
        guard let window = notification.object as? NSWindow else { return }
        let newScale = window.backingScaleFactor
        logger.debug("Window backing scale factor changed to \(newScale)")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Request clipboard from guest when window becomes active
        stream.requestClipboard(format: .plainText)
    }

    // MARK: - Window Visibility

    func windowDidMiniaturize(_ notification: Notification) {
        logger.debug("Window minimized, pausing stream")
        stream.pause()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        logger.debug("Window restored from dock, resuming stream")
        stream.resume()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Pause stream when window is fully occluded (covered by other windows)
        if window.occlusionState.contains(.visible) {
            logger.debug("Window became visible, resuming stream")
            stream.resume()
        } else {
            logger.debug("Window fully occluded, pausing stream")
            stream.pause()
        }
    }
}

// MARK: - ClipboardManagerDelegate

@available(macOS 13, *)
extension WinRunWindowController: ClipboardManagerDelegate {
    func clipboardManager(_ manager: ClipboardManager, didDetectHostClipboardChange clipboard: ClipboardData) {
        // Send host clipboard to Windows guest
        stream.sendClipboard(clipboard)
    }
}
