import UIKit
import Metal
import CoreVideo
import QuartzCore

/// Renders decoded BGRA `CVPixelBuffer`s to a `CAMetalLayer`, applying the magnifier zoom IN the
/// shader (sampling a sub-rect of the frame into the full-res drawable) rather than as a Core
/// Animation transform.
///
/// Rendering is driven by a **display-link `tick()`** (see `MetalVideoUIView`), not by video-frame
/// arrival: each vsync the rendered window EASES toward `targetWindow` (the cursor-follow target, in
/// display-normalized coords) and is mapped into the latest frame's region. This restores smooth,
/// display-rate cursor-follow (a video frame arriving at 30 fps no longer makes the pan step at 30 fps)
/// while keeping the zoom in-shader (no tear, crisp, invariant to host re-crops). `submit` just stores
/// the newest frame; `tick` does the drawing.
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

    /// The display-normalized window to show (cursor-follow target), set by the session. The rendered
    /// window eases toward it at display rate.
    var targetWindow = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Per-vsync easing fraction toward `targetWindow` (smaller = smoother/laggier). Tunable on device.
    var easingFactor: CGFloat = 0.28

    private var currentWindow = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var lastPixelBuffer: CVPixelBuffer?
    private var latestFrameRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var pendingFrame = false

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
        // Present the drawable IN the CATransaction so a present can't tear against the compositor.
        layer.presentsWithTransaction = true
        layer.maximumDrawableCount = 3
        self.layer = layer
    }

    /// Store the newest decoded frame + the display region it shows. Drawing happens in `tick`.
    func submit(_ pixelBuffer: CVPixelBuffer, region: CGRect) {
        lastPixelBuffer = pixelBuffer
        latestFrameRegion = (region.width > 0 && region.height > 0) ? region : CGRect(x: 0, y: 0, width: 1, height: 1)
        pendingFrame = true
    }

    /// One display-link step: ease the window toward the target and redraw the latest frame if the
    /// window moved or a new frame arrived. Idle (settled + no new frame) → no work. `frameDuration`
    /// time-normalizes the easing so the follow feels the same at 60 and 120 Hz.
    func tick(frameDuration: CFTimeInterval) {
        guard let buffer = lastPixelBuffer else { return }
        let factor = Self.perTickFactor(easingFactor, frameDuration: frameDuration)
        let next = Self.easedWindow(current: currentWindow, target: targetWindow, factor: factor)
        let moved = next != currentWindow
        currentWindow = next
        guard moved || pendingFrame else { return }
        pendingFrame = false
        render(buffer, sampleRect: Self.sampleRect(window: currentWindow, in: latestFrameRegion))
    }

    /// Snap the rendered window to the target instantly (no ease) — used on a display switch / zoom
    /// reset so the picture cuts over instead of animating across from the old display's window.
    func snapWindow() { currentWindow = targetWindow }

    /// Convert the per-1/60s `easingFactor` into the fraction to apply for an actual `frameDuration`,
    /// so wall-clock convergence is refresh-rate-independent (120 Hz applies a smaller fraction, twice).
    static func perTickFactor(_ base: CGFloat, frameDuration dt: CFTimeInterval) -> CGFloat {
        guard dt > 0 else { return base }
        return 1 - pow(1 - base, CGFloat(dt) * 60)
    }

    private func render(_ pixelBuffer: CVPixelBuffer, sampleRect rect: CGRect) {
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

        // Aspect-fit the SAMPLED region (its pixel size), not the whole frame: at zoom 1 the window is
        // the full frame → the usual letterbox; zoomed in it's the window sub-rect whose aspect matches
        // the view → fills it. The fragment samples sampleRect.origin + uv * sampleRect.size.
        let sampledPixels = CGSize(width: Double(width) * rect.width, height: Double(height) * rect.height)
        var scale = Self.aspectFitScale(content: sampledPixels, into: layer.drawableSize)
        var uvRect = SIMD4<Float>(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&uvRect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // With presentsWithTransaction we present manually after the buffer is scheduled, on the main
        // actor (this runs in the display-link's runloop turn), so the present joins its CATransaction.
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }

    /// Map a display-normalized `window` into a frame's `region`, in texture UV. NOT clamped to [0,1]:
    /// a window past a not-yet-re-cropped frame edge-clamps via the sampler while keeping its true size
    /// (so the renderer aspect-fits it to the same on-screen rect instead of pinching to a sliver).
    static func sampleRect(window: CGRect, in region: CGRect) -> CGRect {
        guard region.width > 0, region.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: (window.minX - region.minX) / region.width,
                      y: (window.minY - region.minY) / region.height,
                      width: max(0.0001, window.width / region.width),
                      height: max(0.0001, window.height / region.height))
    }

    /// Move `current` a `factor` of the way toward `target` per call; snap when within epsilon (so it
    /// settles exactly and `tick` can go idle). Pure for testing.
    static func easedWindow(current: CGRect, target: CGRect, factor: CGFloat) -> CGRect {
        let epsilon: CGFloat = 0.0001
        func ease(_ c: CGFloat, _ t: CGFloat) -> CGFloat { abs(t - c) < epsilon ? t : c + (t - c) * factor }
        return CGRect(x: ease(current.minX, target.minX), y: ease(current.minY, target.minY),
                      width: ease(current.width, target.width), height: ease(current.height, target.height))
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
        fragment float4 portview_fragment(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]], constant float4 &uvRect [[buffer(0)]]) {
            float2 sampleUV = uvRect.xy + in.uv * uvRect.zw;
            return tex.sample(s, sampleUV);
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

/// A UIView backed by a `CAMetalLayer`; keeps the drawable sized to the view in device pixels and
/// drives the renderer from a `CADisplayLink` so the cursor-follow pan is smooth at display rate
/// (decoupled from video-frame arrival).
final class MetalVideoUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    weak var renderer: MetalVideoRenderer?
    private var displayLink: CADisplayLink?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        renderer?.tick(frameDuration: link.targetTimestamp - link.timestamp)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    deinit { displayLink?.invalidate() }
}
