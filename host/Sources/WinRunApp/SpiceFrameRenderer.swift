import Foundation
import Metal
import MetalKit
import simd

/// GPU-accelerated renderer for Spice window frames using Metal.
///
/// This renderer receives raw BGRA pixel buffers from the Spice stream and
/// displays them efficiently using Metal textures. It handles:
/// - Retina display scaling (backing scale factor)
/// - Dynamic texture resizing when window dimensions change
/// - Efficient buffer-to-texture uploads
@available(macOS 13, *)
public final class SpiceFrameRenderer: NSObject, MTKViewDelegate {
    
    // MARK: - Metal Infrastructure
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    
    // MARK: - Frame State
    
    private var currentTexture: MTLTexture?
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    private var scaleFactor: CGFloat = 1.0
    
    /// Lock to protect texture access during concurrent frame updates
    private let textureLock = NSLock()
    
    // MARK: - Quad Vertices (Full-screen textured quad)
    
    private let vertexBuffer: MTLBuffer
    
    // MARK: - Initialization
    
    public override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("SpiceFrameRenderer: Metal is not supported on this device")
        }
        
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("SpiceFrameRenderer: Failed to create Metal command queue")
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        // Create pipeline state
        self.pipelineState = SpiceFrameRenderer.createPipelineState(device: device)
        
        // Create sampler state for texture filtering
        self.samplerState = SpiceFrameRenderer.createSamplerState(device: device)
        
        // Create vertex buffer for full-screen quad
        self.vertexBuffer = SpiceFrameRenderer.createQuadVertexBuffer(device: device)
        
        super.init()
    }
    
    // MARK: - Public Interface
    
    /// Configure the MTKView for rendering
    public func configure(view: MTKView) {
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        view.isPaused = false
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
    }
    
    /// Update the renderer with a new frame from the Spice stream
    /// - Parameters:
    ///   - pixelData: Raw BGRA pixel data
    ///   - width: Frame width in pixels
    ///   - height: Frame height in pixels
    ///   - scaleFactor: Display scale factor (1.0 for standard, 2.0 for Retina)
    public func updateFrame(pixelData: Data, width: Int, height: Int, scaleFactor: CGFloat = 1.0) {
        textureLock.lock()
        defer { textureLock.unlock() }
        
        self.scaleFactor = scaleFactor
        
        // Recreate texture if dimensions changed
        if textureWidth != width || textureHeight != height || currentTexture == nil {
            currentTexture = createTexture(width: width, height: height)
            textureWidth = width
            textureHeight = height
        }
        
        guard let texture = currentTexture else { return }
        
        // Upload pixel data to texture
        let bytesPerRow = width * 4 // BGRA = 4 bytes per pixel
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        pixelData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
    }
    
    /// Update only the scale factor without providing new pixel data
    public func updateScaleFactor(_ scaleFactor: CGFloat) {
        textureLock.lock()
        self.scaleFactor = scaleFactor
        textureLock.unlock()
    }
    
    /// Clear the current frame (shows default background)
    public func clearFrame() {
        textureLock.lock()
        currentTexture = nil
        textureWidth = 0
        textureHeight = 0
        textureLock.unlock()
    }
    
    // MARK: - MTKViewDelegate
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle view resize - the Metal view will automatically handle backing scale
    }
    
    public func draw(in view: MTKView) {
        textureLock.lock()
        let texture = currentTexture
        textureLock.unlock()
        
        guard let texture = texture,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        
        // Draw the quad (6 vertices for 2 triangles)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // MARK: - Private Helpers
    
    private func createTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
    
    private static func createPipelineState(device: MTLDevice) -> MTLRenderPipelineState {
        let library: MTLLibrary
        
        // Try to load from default library, fall back to creating from source
        if let defaultLibrary = device.makeDefaultLibrary() {
            library = defaultLibrary
        } else {
            // Compile shaders from source
            let shaderSource = Self.metalShaderSource
            do {
                library = try device.makeLibrary(source: shaderSource, options: nil)
            } catch {
                fatalError("SpiceFrameRenderer: Failed to compile Metal shaders: \(error)")
            }
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "spiceVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "spiceFragmentShader")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("SpiceFrameRenderer: Failed to create render pipeline state: \(error)")
        }
    }
    
    private static func createSamplerState(device: MTLDevice) -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            fatalError("SpiceFrameRenderer: Failed to create sampler state")
        }
        return sampler
    }
    
    private static func createQuadVertexBuffer(device: MTLDevice) -> MTLBuffer {
        // Vertex data: position (x, y) and texture coordinates (u, v)
        // Positions are in normalized device coordinates [-1, 1]
        // Texture coordinates are [0, 1] with origin at top-left
        let vertices: [Float] = [
            // Position      // TexCoord
            -1.0, -1.0,      0.0, 1.0,  // Bottom-left
             1.0, -1.0,      1.0, 1.0,  // Bottom-right
             1.0,  1.0,      1.0, 0.0,  // Top-right
            
            -1.0, -1.0,      0.0, 1.0,  // Bottom-left
             1.0,  1.0,      1.0, 0.0,  // Top-right
            -1.0,  1.0,      0.0, 0.0   // Top-left
        ]
        
        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            fatalError("SpiceFrameRenderer: Failed to create vertex buffer")
        }
        
        return buffer
    }
    
    // MARK: - Embedded Metal Shaders
    
    private static let metalShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    
    struct VertexIn {
        float2 position [[attribute(0)]];
        float2 texCoord [[attribute(1)]];
    };
    
    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };
    
    vertex VertexOut spiceVertexShader(uint vertexID [[vertex_id]],
                                        constant float4 *vertexData [[buffer(0)]]) {
        // Each vertex has 4 floats: x, y, u, v
        float4 data = vertexData[vertexID];
        
        VertexOut out;
        out.position = float4(data.xy, 0.0, 1.0);
        out.texCoord = data.zw;
        return out;
    }
    
    fragment float4 spiceFragmentShader(VertexOut in [[stage_in]],
                                         texture2d<float> texture [[texture(0)]],
                                         sampler textureSampler [[sampler(0)]]) {
        return texture.sample(textureSampler, in.texCoord);
    }
    """
}
