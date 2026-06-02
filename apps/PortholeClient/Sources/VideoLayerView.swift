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

/// Video display plus trackpad-style input: one-finger pan moves the cursor, two-finger
/// pan scrolls, tap clicks. Deltas are forwarded incrementally as the gesture updates.
struct TrackpadVideoView: UIViewRepresentable {
    let renderer: VideoRenderer
    let onMove: (CGFloat, CGFloat) -> Void
    let onScroll: (CGFloat, CGFloat) -> Void
    let onClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onScroll: onScroll, onClick: onClick)
    }

    func makeUIView(context: Context) -> SampleBufferUIView {
        let view = SampleBufferUIView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        view.isUserInteractionEnabled = true
        renderer.attach(view.displayLayer)

        let coordinator = context.coordinator
        let move = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleMove(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(move)
        view.addGestureRecognizer(scroll)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: SampleBufferUIView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let onMove: (CGFloat, CGFloat) -> Void
        let onScroll: (CGFloat, CGFloat) -> Void
        let onClick: () -> Void
        private var lastMove: CGPoint = .zero
        private var lastScroll: CGPoint = .zero

        init(onMove: @escaping (CGFloat, CGFloat) -> Void,
             onScroll: @escaping (CGFloat, CGFloat) -> Void,
             onClick: @escaping () -> Void) {
            self.onMove = onMove
            self.onScroll = onScroll
            self.onClick = onClick
        }

        @objc func handleMove(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            if gesture.state == .began { lastMove = .zero }
            onMove(translation.x - lastMove.x, translation.y - lastMove.y)
            lastMove = translation
        }

        @objc func handleScroll(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            if gesture.state == .began { lastScroll = .zero }
            onScroll(translation.x - lastScroll.x, translation.y - lastScroll.y)
            lastScroll = translation
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            onClick()
        }
    }
}
