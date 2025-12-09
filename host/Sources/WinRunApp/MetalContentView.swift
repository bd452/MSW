import Foundation
import AppKit
import MetalKit

/// NSView subclass that hosts a Metal rendering surface for Spice frames.
///
/// This view automatically handles:
/// - Retina display scaling via the backing scale factor
/// - Window resize events
/// - Proper layer hosting for Metal content
@available(macOS 13, *)
public final class MetalContentView: NSView {
    
    // MARK: - Components
    
    private let metalView: MTKView
    private let renderer: SpiceFrameRenderer
    
    /// Current scale factor for Retina support
    private var currentScaleFactor: CGFloat = 1.0
    
    /// Expected frame dimensions from the Spice stream
    private var expectedFrameSize: CGSize = .zero
    
    // MARK: - Initialization
    
    public init(frame frameRect: NSRect, renderer: SpiceFrameRenderer) {
        self.renderer = renderer
        self.metalView = MTKView(frame: frameRect)
        
        super.init(frame: frameRect)
        
        setupMetalView()
    }
    
    public convenience init(renderer: SpiceFrameRenderer) {
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
    
    // MARK: - View Lifecycle
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScaleFactorFromWindow()
    }
    
    public override func viewDidChangeBackingProperties() {
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
    public func updateFrame(pixelData: Data, width: Int, height: Int, guestScaleFactor: CGFloat = 1.0) {
        let combinedScale = currentScaleFactor * guestScaleFactor
        renderer.updateFrame(pixelData: pixelData, width: width, height: height, scaleFactor: combinedScale)
        
        expectedFrameSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        
        // Trigger redraw
        metalView.needsDisplay = true
    }
    
    /// Clear the current frame
    public func clearFrame() {
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
    public var idealSize: CGSize {
        guard expectedFrameSize.width > 0 && expectedFrameSize.height > 0 else {
            return CGSize(width: 800, height: 600) // Default size
        }
        
        // Return the frame size in points (scaled down for Retina if needed)
        return CGSize(
            width: expectedFrameSize.width / currentScaleFactor,
            height: expectedFrameSize.height / currentScaleFactor
        )
    }
    
    public override var intrinsicContentSize: NSSize {
        return idealSize
    }
}
