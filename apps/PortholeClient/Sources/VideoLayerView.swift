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

/// Video display plus trackpad-style input: one-finger pan moves the cursor, two-finger pan
/// scrolls, tap clicks, pinch reports a zoom factor. The actual zoom/pan render and cursor
/// centering are applied by the parent in SwiftUI (`scaleEffect`/`offset`), which is reliable;
/// a raw transform on this view's backing layer is fought by layout.
struct TrackpadVideoView: UIViewRepresentable {
    let renderer: VideoRenderer
    let zoom: CGFloat
    let onMove: (CGFloat, CGFloat) -> Void
    let onScroll: (CGFloat, CGFloat) -> Void
    let onClick: () -> Void
    let onZoom: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onScroll: onScroll, onClick: onClick, onZoom: onZoom)
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
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        for recognizer in [move, scroll, tap, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: SampleBufferUIView, context: Context) {
        context.coordinator.currentZoom = zoom
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onMove: (CGFloat, CGFloat) -> Void
        let onScroll: (CGFloat, CGFloat) -> Void
        let onClick: () -> Void
        let onZoom: (CGFloat) -> Void
        var currentZoom: CGFloat = 1
        private var lastMove: CGPoint = .zero
        private var lastScroll: CGPoint = .zero
        private var pinchStart: CGFloat = 1

        init(onMove: @escaping (CGFloat, CGFloat) -> Void,
             onScroll: @escaping (CGFloat, CGFloat) -> Void,
             onClick: @escaping () -> Void,
             onZoom: @escaping (CGFloat) -> Void) {
            self.onMove = onMove
            self.onScroll = onScroll
            self.onClick = onClick
            self.onZoom = onZoom
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

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began: pinchStart = currentZoom
            case .changed, .ended: onZoom(pinchStart * gesture.scale)
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
