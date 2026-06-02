import SwiftUI
import UIKit
import AVFoundation
import CoreMedia

/// Renders decoded video by enqueueing `CMSampleBuffer`s into an `AVSampleBufferDisplayLayer`,
/// which handles hardware decode + display. Simple first render path (production: Metal/CAMetalLayer).
@MainActor
final class VideoRenderer {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        markDisplayImmediately(sampleBuffer)
        displayLayer?.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    /// Without a control timebase, the layer needs each sample flagged for immediate display.
    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

/// A UIView backed by an `AVSampleBufferDisplayLayer`.
final class SampleBufferUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct VideoLayerView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> SampleBufferUIView {
        let view = SampleBufferUIView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        renderer.attach(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferUIView, context: Context) {}
}
