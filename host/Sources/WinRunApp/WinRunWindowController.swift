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
final class WinRunWindowController: NSObject, SpiceWindowStreamDelegate, MetalContentViewInputDelegate, SpiceControlChannelDelegate {
    private var window: NSWindow?
    private let renderer: SpiceFrameRenderer
    private var metalContentView: MetalContentView?
    private let stream: SpiceWindowStream
    private let controlChannel: SpiceControlChannel
    private let frameRouter: SpiceFrameRouter
    private let logger: Logger

    /// Current metadata from the Spice stream
    private var currentMetadata: WindowMetadata?
    private var activeWindowID: UInt64 = 0
    private var routedWindowIDs: Set<UInt64> = []
    private var sharedMemoryMapping: SharedMemoryFileMapping?

    /// Clipboard synchronization
    private let clipboardManager: ClipboardManager

    override init() {
        self.logger = StandardLogger(subsystem: "WinRunWindowController")
        self.stream = SpiceWindowStream(configuration: SpiceStreamConfiguration.environmentDefault())
        self.controlChannel = SpiceControlChannel(configuration: SpiceStreamConfiguration.environmentDefault())
        self.frameRouter = SpiceFrameRouter(logger: StandardLogger(subsystem: "SpiceFrameRouter"))
        self.renderer = SpiceFrameRenderer()
        self.clipboardManager = ClipboardManager()
        super.init()
        stream.delegate = self
        controlChannel.delegate = self
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
        metalView.windowID = activeWindowID
        metalView.updateConnectionState(.connecting)
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
        configureSharedMemoryRegionIfAvailable()
        registerStreamRouting(for: activeWindowID)

        logger.info("Window created with Metal rendering layer and input forwarding")
        stream.connect(toWindowID: activeWindowID)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.controlChannel.connect()
            } catch {
                self.logger.warn("Failed to connect control channel: \(error)")
            }
        }
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
        Task { [weak self] in
            guard let self else { return }
            if await !self.controlChannel.connected {
                try? await self.controlChannel.connect()
            }
        }
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

    func windowStream(_ stream: SpiceWindowStream, didReceiveSharedFrame frame: SharedFrame) {
        guard let metalView = metalContentView else { return }
        let guestScale = currentMetadata?.scaleFactor ?? 1.0
        renderer.updateFrame(from: frame, scaleFactor: guestScale)
        metalView.needsDisplay = true
    }

    func windowStream(_ stream: SpiceWindowStream, didUpdateMetadata metadata: WindowMetadata) {
        applyMetadata(metadata)
    }

    func windowStream(_ stream: SpiceWindowStream, didChangeState state: SpiceConnectionState) {
        logger.debug("Spice stream state changed: \(state)")
        metalContentView?.updateConnectionState(state)
    }

    func windowStreamDidClose(_ stream: SpiceWindowStream) {
        logger.info("Spice stream closed")
        metalContentView?.clearFrame()
    }

    func windowStream(_ stream: SpiceWindowStream, didReceiveClipboard clipboard: ClipboardData) {
        // Update macOS pasteboard with clipboard data from Windows guest
        clipboardManager.setFromGuest(clipboard)
    }

    // MARK: - SpiceControlChannelDelegate

    func controlChannelDidConnect(_ channel: SpiceControlChannel) {
        logger.info("Control channel connected")
        DispatchQueue.main.async { [weak self] in
            self?.configureSharedMemoryRegionIfAvailable()
        }
    }

    func controlChannelDidDisconnect(_ channel: SpiceControlChannel) {
        logger.info("Control channel disconnected")
    }

    func controlChannel(
        _ channel: SpiceControlChannel,
        didReceiveMessage message: Any,
        type: SpiceMessageType
    ) {
        guard type == .windowMetadata, let metadataMessage = message as? WindowMetadataMessage else {
            return
        }

        handleWindowMetadataMessage(metadataMessage)
    }

    func controlChannel(
        _ channel: SpiceControlChannel,
        didReceiveFrameReady notification: FrameReadyMessage
    ) {
        frameRouter.routeFrameReady(notification)
    }

    func controlChannel(
        _ channel: SpiceControlChannel,
        didReceiveBufferAllocation notification: WindowBufferAllocatedMessage
    ) {
        if notification.usesSharedMemory {
            DispatchQueue.main.async { [weak self] in
                self?.configureSharedMemoryRegionIfAvailable()
            }
        }
        frameRouter.handleBufferAllocation(notification)
    }

    // MARK: - Internal Helpers

    private func handleWindowMetadataMessage(_ message: WindowMetadataMessage) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if self.activeWindowID == 0, message.windowId != 0, message.eventType != .destroyed {
                self.activeWindowID = message.windowId
                self.metalContentView?.windowID = message.windowId
                self.registerStreamRouting(for: message.windowId)
                self.logger.info("Using guest window ID \(message.windowId) for input targeting")
            }

            guard message.windowId == self.activeWindowID else {
                return
            }

            if message.eventType == .destroyed {
                self.logger.info("Guest window \(message.windowId) destroyed")
                self.window?.close()
                return
            }

            self.applyMetadata(self.makeWindowMetadata(from: message))
        }
    }

    private func applyMetadata(_ metadata: WindowMetadata) {
        currentMetadata = metadata
        metalContentView?.windowID = metadata.windowID

        guard let window else { return }

        window.title = metadata.title

        if metadata.frame.width > 0 && metadata.frame.height > 0 {
            let backingScale = window.backingScaleFactor
            let pointWidth = metadata.frame.width / backingScale
            let pointHeight = metadata.frame.height / backingScale

            let currentSize = window.contentView?.frame.size ?? .zero
            let widthDelta = abs(currentSize.width - pointWidth)
            let heightDelta = abs(currentSize.height - pointHeight)

            if widthDelta > 10 || heightDelta > 10 {
                window.setContentSize(NSSize(width: pointWidth, height: pointHeight))
                logger.debug("Resized window to \(Int(pointWidth))x\(Int(pointHeight)) points")
            }
        }

        if metadata.isResizable {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
    }

    private func makeWindowMetadata(from message: WindowMetadataMessage) -> WindowMetadata {
        let rect = CGRect(
            x: Double(message.bounds.x),
            y: Double(message.bounds.y),
            width: Double(message.bounds.width),
            height: Double(message.bounds.height)
        )

        return WindowMetadata(
            windowID: message.windowId,
            title: message.title,
            frame: rect,
            isResizable: message.isResizable,
            scaleFactor: message.scaleFactor
        )
    }

    private func registerStreamRouting(for windowID: UInt64) {
        guard !routedWindowIDs.contains(windowID) else { return }
        routedWindowIDs.insert(windowID)
        frameRouter.registerStream(stream, forWindowID: windowID)
    }

    private func unregisterAllStreamRouting() {
        for windowID in routedWindowIDs {
            frameRouter.unregisterStream(forWindowID: windowID)
        }
        routedWindowIDs.removeAll()
    }

    private func configureSharedMemoryRegionIfAvailable() {
        guard sharedMemoryMapping == nil else { return }

        do {
            let mapping = try SharedMemoryFileMapping(path: sharedMemoryPath())
            sharedMemoryMapping = mapping
            frameRouter.setSharedMemoryRegion(basePointer: mapping.pointer, size: mapping.size)
            logger.info("Configured shared frame memory mapping at \(mapping.path)")
        } catch {
            logger.debug("Shared frame memory not ready yet: \(error)")
        }
    }

    private func sharedMemoryPath() -> String {
        if let envPath = ProcessInfo.processInfo.environment["WINRUN_FRAMEBUFFER_SHM_PATH"], !envPath.isEmpty {
            return envPath
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/WinRun/SharedMemory/framebuffer.shm"
    }
}

// MARK: - NSWindowDelegate

@available(macOS 13, *)
extension WinRunWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Disconnect the stream when window is closed by user
        clipboardManager.stopMonitoring()
        unregisterAllStreamRouting()
        frameRouter.clearSharedMemoryRegion()
        sharedMemoryMapping = nil
        stream.disconnect()
        Task { [weak self] in
            await self?.controlChannel.disconnect()
        }
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
private enum SharedMemoryMappingError: Error, CustomStringConvertible {
    case fileMissing(String)
    case statFailed(String)
    case emptyFile(String)
    case openFailed(String)
    case mapFailed(String)

    var description: String {
        switch self {
        case .fileMissing(let path):
            return "Shared memory file missing at \(path)"
        case .statFailed(let path):
            return "Failed to stat shared memory file at \(path)"
        case .emptyFile(let path):
            return "Shared memory file is empty at \(path)"
        case .openFailed(let path):
            return "Failed to open shared memory file at \(path)"
        case .mapFailed(let path):
            return "Failed to mmap shared memory file at \(path)"
        }
    }
}

@available(macOS 13, *)
private final class SharedMemoryFileMapping {
    let path: String
    let pointer: UnsafeMutableRawPointer
    let size: Int

    private let fileDescriptor: Int32

    init(path: String) throws {
        self.path = path

        guard FileManager.default.fileExists(atPath: path) else {
            throw SharedMemoryMappingError.fileMissing(path)
        }

        var fileInfo = stat()
        let statResult = path.withCString { cPath in
            Darwin.stat(cPath, &fileInfo)
        }
        guard statResult == 0 else {
            throw SharedMemoryMappingError.statFailed(path)
        }

        let fileSize = Int(fileInfo.st_size)
        guard fileSize > 0 else {
            throw SharedMemoryMappingError.emptyFile(path)
        }

        let fd = path.withCString { cPath in
            Darwin.open(cPath, O_RDWR)
        }
        guard fd >= 0 else {
            throw SharedMemoryMappingError.openFailed(path)
        }

        let mapped = mmap(nil, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED, let basePointer = mapped else {
            close(fd)
            throw SharedMemoryMappingError.mapFailed(path)
        }

        self.fileDescriptor = fd
        self.pointer = basePointer
        self.size = fileSize
    }

    deinit {
        munmap(pointer, size)
        close(fileDescriptor)
    }
}
