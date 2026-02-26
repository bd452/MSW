import Foundation
import AppKit
import Darwin
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
    private let controlChannel: SpiceControlChannel
    private let frameRouter: SpiceFrameRouter
    private let logger: Logger
    private var currentWindowID: UInt64 = 0
    private var sharedMemoryRegion: MappedSharedMemoryRegion?
    private var isTearingDown = false

    /// Current metadata from the Spice stream
    private var currentMetadata: WindowMetadata?

    /// Clipboard synchronization
    private let clipboardManager: ClipboardManager

    override init() {
        let logger = StandardLogger(subsystem: "WinRunWindowController")
        let streamConfiguration = SpiceStreamConfiguration.environmentDefault()
        self.logger = logger
        self.stream = SpiceWindowStream(configuration: streamConfiguration)
        self.controlChannel = SpiceControlChannel(configuration: streamConfiguration, logger: logger)
        self.frameRouter = SpiceFrameRouter(logger: logger)
        self.renderer = SpiceFrameRenderer()
        self.clipboardManager = ClipboardManager()
        super.init()
        stream.delegate = self
        clipboardManager.delegate = self
        controlChannel.delegate = frameRouter
    }

    func presentWindow(title: String, windowID: UInt64 = 0) {
        currentWindowID = windowID
        isTearingDown = false
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
        metalView.windowID = windowID
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

        // Route FrameReady notifications for this stream and attach shared memory if available.
        frameRouter.registerStream(stream, forWindowID: windowID)
        configureSharedMemoryRoutingIfNeeded()
        Task { [weak self] in
            await self?.connectControlChannelIfNeeded()
        }

        logger.info("Window created with Metal rendering layer and input forwarding (windowID=\(windowID))")
        stream.connect(toWindowID: windowID)
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

    func windowStream(_ stream: SpiceWindowStream, didReceiveSharedFrame frame: SharedFrame) {
        guard let metalView = metalContentView else { return }
        let scaleFactor = currentMetadata?.scaleFactor ?? 1.0
        metalView.updateFrame(sharedFrame: frame, guestScaleFactor: scaleFactor)
    }

    func windowStream(_ stream: SpiceWindowStream, didChangeState state: SpiceConnectionState) {
        logger.debug("Spice stream state changed: \(state)")
        if sharedMemoryRegion == nil {
            configureSharedMemoryRoutingIfNeeded()
        }
        metalContentView?.updateConnectionState(state)
    }

    func windowStreamDidClose(_ stream: SpiceWindowStream) {
        logger.info("Spice stream closed, closing window")
        tearDownConnections()
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
        if !isTearingDown {
            stream.disconnect()
        }
        tearDownConnections()
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

@available(macOS 13, *)
private extension WinRunWindowController {
    func connectControlChannelIfNeeded() async {
        do {
            if await !controlChannel.connected {
                try await controlChannel.connect()
                logger.info("Connected Spice control channel for frame routing")
            }
        } catch {
            logger.error("Failed to connect Spice control channel: \(error)")
        }
    }

    func configureSharedMemoryRoutingIfNeeded() {
        if let region = sharedMemoryRegion {
            frameRouter.setSharedMemoryRegion(basePointer: region.pointer, size: region.size)
            return
        }

        let candidatePaths = sharedMemoryPathCandidates()
        var mapped: MappedSharedMemoryRegion?

        for candidate in candidatePaths {
            if let region = MappedSharedMemoryRegion.open(fileURL: candidate, logger: logger) {
                mapped = region
                break
            }
        }

        guard let region = mapped else {
            logger.warn("Shared frame buffer file not available (checked \(candidatePaths.count) paths)")
            return
        }

        sharedMemoryRegion = region
        frameRouter.setSharedMemoryRegion(basePointer: region.pointer, size: region.size)
        logger.info("Attached shared frame buffer at \(region.fileURL.path): \(region.size / 1024 / 1024) MB")
    }

    func tearDownConnections() {
        guard !isTearingDown else { return }
        isTearingDown = true

        clipboardManager.stopMonitoring()
        frameRouter.unregisterStream(forWindowID: currentWindowID)
        frameRouter.clearSharedMemoryRegion()
        sharedMemoryRegion = nil
        currentMetadata = nil

        Task { [controlChannel] in
            await controlChannel.disconnect()
        }
    }

    func sharedMemoryPathCandidates() -> [URL] {
        var paths: [URL] = []

        if let explicitPath = ProcessInfo.processInfo.environment["WINRUN_FRAMEBUFFER_PATH"],
           !explicitPath.isEmpty {
            paths.append(URL(fileURLWithPath: explicitPath))
        }

        let userDefault = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WinRun/SharedMemory/framebuffer.shm")
        paths.append(userDefault)

        // Some launchd configurations run the daemon as root.
        // In that case the shared-memory file is created under /var/root.
        let rootDefault = URL(fileURLWithPath: "/var/root/Library/Application Support/WinRun/SharedMemory/framebuffer.shm")
        if rootDefault.path != userDefault.path {
            paths.append(rootDefault)
        }

        return paths
    }
}

/// Represents a memory-mapped shared frame buffer file in the host process.
private final class MappedSharedMemoryRegion {
    let fileURL: URL
    let pointer: UnsafeMutableRawPointer
    let size: Int
    private let fileDescriptor: Int32

    private init(fileURL: URL, pointer: UnsafeMutableRawPointer, size: Int, fileDescriptor: Int32) {
        self.fileURL = fileURL
        self.pointer = pointer
        self.size = size
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        munmap(pointer, size)
        close(fileDescriptor)
    }

    static func open(fileURL: URL, logger: Logger) -> MappedSharedMemoryRegion? {
        let fd = Darwin.open(fileURL.path, O_RDWR)
        guard fd >= 0 else { return nil }

        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0, fileStat.st_size > 0 else {
            close(fd)
            return nil
        }

        let size = Int(fileStat.st_size)
        guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else {
            logger.error("Failed to map shared frame buffer at \(fileURL.path)")
            close(fd)
            return nil
        }

        return MappedSharedMemoryRegion(
            fileURL: fileURL,
            pointer: mapped,
            size: size,
            fileDescriptor: fd
        )
    }
}
