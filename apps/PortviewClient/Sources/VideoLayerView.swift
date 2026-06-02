import SwiftUI
import UIKit

/// Video display plus trackpad-style input: one-finger pan moves the cursor, two-finger pan
/// scrolls, tap clicks, pinch reports a zoom factor. The actual zoom/pan render and cursor
/// centering are applied by the parent in SwiftUI (`scaleEffect`/`offset`), which is reliable;
/// a raw transform on this view's backing layer is fought by layout.
struct TrackpadVideoView: UIViewRepresentable {
    let renderer: MetalVideoRenderer
    let zoom: CGFloat
    let onMove: (CGFloat, CGFloat) -> Void
    let onScroll: (CGFloat, CGFloat) -> Void
    let onClick: () -> Void
    let onZoom: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onScroll: onScroll, onClick: onClick, onZoom: onZoom)
    }

    func makeUIView(context: Context) -> MetalVideoUIView {
        let view = MetalVideoUIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = true
        renderer.attach(view.metalLayer)

        let coordinator = context.coordinator
        let move = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleMove(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        coordinator.scrollRecognizer = scroll
        coordinator.pinchRecognizer = pinch
        for recognizer in [move, scroll, tap, pinch] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: MetalVideoUIView, context: Context) {
        context.coordinator.currentZoom = zoom
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let onMove: (CGFloat, CGFloat) -> Void
        let onScroll: (CGFloat, CGFloat) -> Void
        let onClick: () -> Void
        let onZoom: (CGFloat) -> Void
        var currentZoom: CGFloat = 1
        weak var scrollRecognizer: UIPanGestureRecognizer?
        weak var pinchRecognizer: UIPinchGestureRecognizer?
        private var lastMove: CGPoint = .zero
        private var lastScroll: CGPoint = .zero
        private var pinchStart: CGFloat = 1

        /// A two-finger gesture locks to exactly one intent on its first decisive movement,
        /// so scrolling never doubles as zooming (and vice versa) within the same gesture.
        private enum TwoFingerMode { case undecided, scroll, zoom }
        private var twoFingerMode: TwoFingerMode = .undecided

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
            let translation = gesture.translation(in: nil) // window space: zoom-independent
            if gesture.state == .began { lastMove = .zero }
            onMove(translation.x - lastMove.x, translation.y - lastMove.y)
            lastMove = translation
        }

        @objc func handleScroll(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: nil) // window space: zoom-independent
            switch gesture.state {
            case .began:
                lastScroll = translation
            case .changed:
                decideTwoFingerMode()
                guard twoFingerMode == .scroll else {
                    // Not (yet) scrolling — keep the baseline current so a late commit
                    // starts from a zero delta instead of jumping.
                    lastScroll = translation
                    return
                }
                onScroll(translation.x - lastScroll.x, translation.y - lastScroll.y)
                lastScroll = translation
            case .ended, .cancelled, .failed:
                resetTwoFingerIfDone()
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            onClick()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                pinchStart = currentZoom
            case .changed:
                decideTwoFingerMode()
                guard twoFingerMode == .zoom else {
                    // Rebase so committing to zoom later doesn't snap the scale.
                    pinchStart = currentZoom / gesture.scale
                    return
                }
                onZoom(pinchStart * gesture.scale)
            case .ended:
                if twoFingerMode == .zoom { onZoom(pinchStart * gesture.scale) }
                resetTwoFingerIfDone()
            case .cancelled, .failed:
                resetTwoFingerIfDone()
            default:
                break
            }
        }

        /// Commit the two-finger gesture to scroll or zoom once one signal clearly dominates.
        private func decideTwoFingerMode() {
            guard twoFingerMode == .undecided else { return }
            let translation = scrollRecognizer?.translation(in: nil) ?? .zero
            let centroidDelta = hypot(translation.x, translation.y)
            let scaleDelta = abs((pinchRecognizer?.scale ?? 1) - 1)
            // Require a minimum signal before committing to avoid jitter at touch-down.
            guard scaleDelta >= 0.04 || centroidDelta >= 12 else { return }
            // ~200 converts a scale fraction into a comparable point magnitude.
            twoFingerMode = (scaleDelta * 200 > centroidDelta) ? .zoom : .scroll
        }

        /// Clear the lock once neither two-finger recognizer is active.
        private func resetTwoFingerIfDone() {
            let active: (UIGestureRecognizer?) -> Bool = { recognizer in
                guard let state = recognizer?.state else { return false }
                return state == .began || state == .changed
            }
            if !active(scrollRecognizer) && !active(pinchRecognizer) {
                twoFingerMode = .undecided
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
