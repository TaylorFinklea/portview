import UIKit
import Metal
import CoreVideo
import QuartzCore

/// Renders decoded BGRA `CVPixelBuffer`s to a `CAMetalLayer`. The host's HEVC is decoded to
/// BGRA by `PortviewMedia.VideoDecoder`, so this is a passthrough: wrap the pixel buffer as a
/// Metal texture (zero-copy via `CVMetalTextureCache`) and draw it aspect-fit into the drawable.
@MainActor
final class MetalVideoRenderer {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let linearSampler: MTLSamplerState?
    private let nearestSampler: MTLSamplerState?
    private var textureCache: CVMetalTextureCache?
    private weak var layer: CAMetalLayer?
    var samplerMode: VideoSamplerMode = .linear

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            pipeline = Self.makePipeline(device: device)
            linearSampler = Self.makeSampler(device: device, filter: .linear)
            nearestSampler = Self.makeSampler(device: device, filter: .nearest)
        } else {
            pipeline = nil
            linearSampler = nil
            nearestSampler = nil
        }
    }

    func attach(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        self.layer = layer
    }

    func render(_ pixelBuffer: CVPixelBuffer) {
        guard let commandQueue, let pipeline, let textureCache, let layer,
              layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable() else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let sourceTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        let sampler = samplerMode == .linear ? linearSampler : nearestSampler
        guard let sampler,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var scale = Self.aspectFitScale(content: CGSize(width: width, height: height), into: layer.drawableSize)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Quad scale (≤1 on the letterboxed axis) that fits `content` inside `drawable`.
    static func aspectFitScale(content: CGSize, into drawable: CGSize) -> SIMD2<Float> {
        guard content.width > 0, content.height > 0, drawable.width > 0, drawable.height > 0 else {
            return SIMD2<Float>(1, 1)
        }
        let contentAspect = content.width / content.height
        let drawableAspect = drawable.width / drawable.height
        if contentAspect > drawableAspect {
            return SIMD2<Float>(1, Float(drawableAspect / contentAspect))
        } else {
            return SIMD2<Float>(Float(contentAspect / drawableAspect), 1)
        }
    }

    private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VSOut { float4 position [[position]]; float2 uv; };
        vertex VSOut portview_vertex(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
            const float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
            const float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
            VSOut out;
            out.position = float4(positions[vid] * scale, 0.0, 1.0);
            out.uv = uvs[vid];
            return out;
        }
        fragment float4 portview_fragment(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
            return tex.sample(s, in.uv);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "portview_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "portview_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeSampler(device: MTLDevice, filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }
}

/// A UIView backed by a `CAMetalLayer`; keeps the drawable sized to the view in device pixels.
final class MetalVideoUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}
