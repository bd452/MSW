import Foundation
import AppKit
import MetalKit
import WinRunShared

/// Delegate protocol for receiving input events from the Metal content view
@available(macOS 13, *)
protocol MetalContentViewInputDelegate: AnyObject {
    func metalContentView(_ view: MetalContentView, didReceiveMouseEvent event: MouseInputEvent)
    func metalContentView(_ view: MetalContentView, didReceiveKeyboardEvent event: KeyboardInputEvent)
    func metalContentView(_ view: MetalContentView, didReceiveDragDropEvent event: DragDropEvent)
}

/// NSView subclass that hosts a Metal rendering surface for Spice frames.
///
/// This view automatically handles:
/// - Retina display scaling via the backing scale factor
/// - Window resize events
/// - Proper layer hosting for Metal content
/// - Mouse, keyboard, and drag/drop event forwarding
@available(macOS 13, *)
final class MetalContentView: NSView {
    
    // MARK: - Components
    
    private let metalView: MTKView
    private let renderer: SpiceFrameRenderer
    
    /// Delegate for input event forwarding
    weak var inputDelegate: MetalContentViewInputDelegate?
    
    /// Window ID for event targeting
    var windowID: UInt64 = 0
    
    /// Current scale factor for Retina support
    private var currentScaleFactor: CGFloat = 1.0
    
    /// Expected frame dimensions from the Spice stream
    private var expectedFrameSize: CGSize = .zero
    
    /// Tracks currently pressed mouse buttons for move events
    private var pressedMouseButtons: Set<MouseButton> = []
    
    // MARK: - Initialization
    
    init(frame frameRect: NSRect, renderer: SpiceFrameRenderer) {
        self.renderer = renderer
        self.metalView = MTKView(frame: frameRect)
        
        super.init(frame: frameRect)
        
        setupMetalView()
        setupInputHandling()
    }
    
    convenience init(renderer: SpiceFrameRenderer) {
        self.init(frame: .zero, renderer: renderer)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
    
    // MARK: - Setup
    
    private func setupMetalView() {
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.wantsLayer = true
        metalView.layerContentsRedrawPolicy = .duringViewResize
        
        // Configure the renderer
        renderer.configure(view: metalView)
        
        // Add as subview with full-frame constraints
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    
    private func setupInputHandling() {
        // Register for drag and drop
        registerForDraggedTypes([.fileURL, .string])
    }
    
    // MARK: - View Lifecycle
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScaleFactorFromWindow()
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaleFactorFromWindow()
    }
    
    // MARK: - Frame Updates
    
    /// Update the view with new frame data from the Spice stream
    /// - Parameters:
    ///   - pixelData: Raw BGRA pixel data
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    ///   - guestScaleFactor: Scale factor reported by the guest (for DPI awareness)
    func updateFrame(pixelData: Data, width: Int, height: Int, guestScaleFactor: CGFloat = 1.0) {
        let combinedScale = currentScaleFactor * guestScaleFactor
        renderer.updateFrame(pixelData: pixelData, width: width, height: height, scaleFactor: combinedScale)
        
        expectedFrameSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        
        // Trigger redraw
        metalView.needsDisplay = true
    }
    
    /// Clear the current frame
    func clearFrame() {
        renderer.clearFrame()
        expectedFrameSize = .zero
        metalView.needsDisplay = true
    }
    
    // MARK: - Retina Support
    
    private func updateScaleFactorFromWindow() {
        guard let window = window else { return }
        
        let newScale = window.backingScaleFactor
        if newScale != currentScaleFactor {
            currentScaleFactor = newScale
            renderer.updateScaleFactor(newScale)
            
            // Update Metal view's drawable size for crisp Retina rendering
            let drawableSize = CGSize(
                width: bounds.width * newScale,
                height: bounds.height * newScale
            )
            metalView.drawableSize = drawableSize
        }
    }
    
    // MARK: - Sizing
    
    /// Returns the ideal size for the view based on the current frame dimensions
    /// and scale factor, for use in window resizing
    var idealSize: CGSize {
        guard expectedFrameSize.width > 0 && expectedFrameSize.height > 0 else {
            return CGSize(width: 800, height: 600) // Default size
        }
        
        // Return the frame size in points (scaled down for Retina if needed)
        return CGSize(
            width: expectedFrameSize.width / currentScaleFactor,
            height: expectedFrameSize.height / currentScaleFactor
        )
    }
    
    override var intrinsicContentSize: NSSize {
        return idealSize
    }
    
    // MARK: - Mouse Event Handling
    
    override var acceptsFirstResponder: Bool { true }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true // Accept mouse clicks even when window isn't focused
    }
    
    override func mouseDown(with event: NSEvent) {
        handleMouseEvent(event, type: .press, button: .left)
        pressedMouseButtons.insert(.left)
    }
    
    override func mouseUp(with event: NSEvent) {
        handleMouseEvent(event, type: .release, button: .left)
        pressedMouseButtons.remove(.left)
    }
    
    override func mouseMoved(with event: NSEvent) {
        handleMouseEvent(event, type: .move, button: nil)
    }
    
    override func mouseDragged(with event: NSEvent) {
        handleMouseEvent(event, type: .move, button: .left)
    }
    
    override func rightMouseDown(with event: NSEvent) {
        handleMouseEvent(event, type: .press, button: .right)
        pressedMouseButtons.insert(.right)
    }
    
    override func rightMouseUp(with event: NSEvent) {
        handleMouseEvent(event, type: .release, button: .right)
        pressedMouseButtons.remove(.right)
    }
    
    override func rightMouseDragged(with event: NSEvent) {
        handleMouseEvent(event, type: .move, button: .right)
    }
    
    override func otherMouseDown(with event: NSEvent) {
        let button = mouseButton(from: event.buttonNumber)
        handleMouseEvent(event, type: .press, button: button)
        pressedMouseButtons.insert(button)
    }
    
    override func otherMouseUp(with event: NSEvent) {
        let button = mouseButton(from: event.buttonNumber)
        handleMouseEvent(event, type: .release, button: button)
        pressedMouseButtons.remove(button)
    }
    
    override func otherMouseDragged(with event: NSEvent) {
        let button = mouseButton(from: event.buttonNumber)
        handleMouseEvent(event, type: .move, button: button)
    }
    
    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let scaledLocation = scalePointToGuestCoordinates(location)
        
        let mouseEvent = MouseInputEvent(
            windowID: windowID,
            eventType: .scroll,
            button: nil,
            x: scaledLocation.x,
            y: scaledLocation.y,
            scrollDeltaX: event.scrollingDeltaX,
            scrollDeltaY: event.scrollingDeltaY,
            modifiers: modifiers(from: event)
        )
        inputDelegate?.metalContentView(self, didReceiveMouseEvent: mouseEvent)
    }
    
    private func handleMouseEvent(_ event: NSEvent, type: MouseEventType, button: MouseButton?) {
        let location = convert(event.locationInWindow, from: nil)
        let scaledLocation = scalePointToGuestCoordinates(location)
        
        let mouseEvent = MouseInputEvent(
            windowID: windowID,
            eventType: type,
            button: button,
            x: scaledLocation.x,
            y: scaledLocation.y,
            modifiers: modifiers(from: event)
        )
        inputDelegate?.metalContentView(self, didReceiveMouseEvent: mouseEvent)
    }
    
    private func mouseButton(from buttonNumber: Int) -> MouseButton {
        switch buttonNumber {
        case 0: return .left
        case 1: return .right
        case 2: return .middle
        case 3: return .extra1
        case 4: return .extra2
        default: return .left
        }
    }
    
    private func scalePointToGuestCoordinates(_ point: NSPoint) -> NSPoint {
        // Convert from macOS coordinate system (origin at bottom-left)
        // to Windows coordinate system (origin at top-left)
        let flippedY = bounds.height - point.y
        
        // Scale to guest pixel coordinates
        return NSPoint(
            x: point.x * currentScaleFactor,
            y: flippedY * currentScaleFactor
        )
    }
    
    // MARK: - Keyboard Event Handling
    
    override func keyDown(with event: NSEvent) {
        handleKeyboardEvent(event, type: .keyDown)
    }
    
    override func keyUp(with event: NSEvent) {
        handleKeyboardEvent(event, type: .keyUp)
    }
    
    override func flagsChanged(with event: NSEvent) {
        // Handle modifier key changes
        let keyCode = KeyCodeMapper.windowsKeyCode(fromMacOS: event.keyCode)
        let isKeyDown = event.modifierFlags.rawValue > 0
        
        let keyboardEvent = KeyboardInputEvent(
            windowID: windowID,
            eventType: isKeyDown ? .keyDown : .keyUp,
            keyCode: keyCode,
            scanCode: UInt32(event.keyCode),
            isExtendedKey: false,
            modifiers: modifiers(from: event),
            character: nil
        )
        inputDelegate?.metalContentView(self, didReceiveKeyboardEvent: keyboardEvent)
    }
    
    private func handleKeyboardEvent(_ event: NSEvent, type: KeyEventType) {
        let keyCode = KeyCodeMapper.windowsKeyCode(fromMacOS: event.keyCode)
        let character = event.characters
        
        // Check for extended keys (right-side modifiers, arrow keys, etc.)
        let isExtendedKey = [0x7B, 0x7C, 0x7D, 0x7E, 0x73, 0x74, 0x75, 0x77, 0x79].contains(Int(event.keyCode))
        
        let keyboardEvent = KeyboardInputEvent(
            windowID: windowID,
            eventType: type,
            keyCode: keyCode,
            scanCode: UInt32(event.keyCode),
            isExtendedKey: isExtendedKey,
            modifiers: modifiers(from: event),
            character: character
        )
        inputDelegate?.metalContentView(self, didReceiveKeyboardEvent: keyboardEvent)
    }
    
    private func modifiers(from event: NSEvent) -> KeyModifiers {
        KeyCodeMapper.modifiers(fromMacOS: event.modifierFlags.rawValue)
    }
    
    // MARK: - Drag and Drop
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        let scaledLocation = scalePointToGuestCoordinates(location)
        let files = extractDraggedFiles(from: sender)
        
        let dragEvent = DragDropEvent(
            windowID: windowID,
            eventType: .enter,
            x: scaledLocation.x,
            y: scaledLocation.y,
            files: files,
            allowedOperations: [.copy]
        )
        inputDelegate?.metalContentView(self, didReceiveDragDropEvent: dragEvent)
        
        return .copy
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        let scaledLocation = scalePointToGuestCoordinates(location)
        
        let dragEvent = DragDropEvent(
            windowID: windowID,
            eventType: .move,
            x: scaledLocation.x,
            y: scaledLocation.y
        )
        inputDelegate?.metalContentView(self, didReceiveDragDropEvent: dragEvent)
        
        return .copy
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        let dragEvent = DragDropEvent(
            windowID: windowID,
            eventType: .leave,
            x: 0,
            y: 0
        )
        inputDelegate?.metalContentView(self, didReceiveDragDropEvent: dragEvent)
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let location = convert(sender.draggingLocation, from: nil)
        let scaledLocation = scalePointToGuestCoordinates(location)
        let files = extractDraggedFiles(from: sender)
        
        let dragEvent = DragDropEvent(
            windowID: windowID,
            eventType: .drop,
            x: scaledLocation.x,
            y: scaledLocation.y,
            files: files,
            selectedOperation: .copy
        )
        inputDelegate?.metalContentView(self, didReceiveDragDropEvent: dragEvent)
        
        return true
    }
    
    private func extractDraggedFiles(from sender: NSDraggingInfo) -> [DraggedFile] {
        guard let pasteboard = sender.draggingPasteboard.propertyList(forType: .fileURL) as? [String] else {
            // Try alternate approach
            if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
                return urls.map { url in
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    
                    // Translate macOS path to Windows path (assuming /Users maps to Z:\)
                    let guestPath = translateToWindowsPath(url.path)
                    
                    return DraggedFile(
                        hostPath: url.path,
                        guestPath: guestPath,
                        fileSize: UInt64(fileSize),
                        isDirectory: isDirectory
                    )
                }
            }
            return []
        }
        
        return pasteboard.map { path in
            let url = URL(fileURLWithPath: path)
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let guestPath = translateToWindowsPath(path)
            
            return DraggedFile(
                hostPath: path,
                guestPath: guestPath,
                fileSize: UInt64(fileSize),
                isDirectory: isDirectory
            )
        }
    }
    
    private func translateToWindowsPath(_ macPath: String) -> String? {
        // Translate /Users/... paths to Z:\ (VirtioFS mount point)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        if macPath.hasPrefix(homeDirectory) {
            let relativePath = String(macPath.dropFirst(homeDirectory.count))
            return "Z:" + relativePath.replacingOccurrences(of: "/", with: "\\")
        }
        return nil
    }
}
