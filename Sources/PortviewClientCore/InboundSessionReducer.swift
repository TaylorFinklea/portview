import CoreGraphics
import PortviewProtocol

/// Pure reducer that folds the state-only deltas of the client session's inbound message loop.
/// Keeping the derivation here (rather than ad hoc in the view model) makes it unit-testable
/// without UIKit: the session loop keeps the effects (decode/render/audio/transport), seeds a
/// snapshot from its current @Published surface, folds a message through `apply`, and writes the
/// changed fields back.
public struct InboundSessionReducer: Equatable, Sendable {
    /// True once a ServerHello has been folded — the loop maps it to `status = .streaming`.
    public private(set) var isStreaming: Bool
    /// Displays the host offered (from ServerHello / DisplaysUpdate) and which one is streaming.
    public private(set) var displays: [DisplayInfo]
    public private(set) var activeDisplayID: UInt32
    /// Host display size in points; used to predict the cursor locally and for the zoom math.
    public private(set) var displaySize: CGSize
    /// Latest cursor position reported by the host, normalized to the display (0…1).
    public private(set) var cursorNormalized: CGPoint
    /// Normalized region of the display the host's current frames represent (the magnifier crop).
    public private(set) var frameViewport: CGRect
    /// True while the host reports its screen locked (capture is the secure desktop / blank).
    public private(set) var hostLocked: Bool

    public init(isStreaming: Bool = false,
                displays: [DisplayInfo] = [],
                activeDisplayID: UInt32 = 0,
                displaySize: CGSize = CGSize(width: 1, height: 1),
                cursorNormalized: CGPoint = CGPoint(x: 0.5, y: 0.5),
                frameViewport: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                hostLocked: Bool = false) {
        self.isStreaming = isStreaming
        self.displays = displays
        self.activeDisplayID = activeDisplayID
        self.displaySize = displaySize
        self.cursorNormalized = cursorNormalized
        self.frameViewport = frameViewport
        self.hostLocked = hostLocked
    }

    public mutating func apply(_ message: AnyMessage) {
        switch message {
        case .serverHello(let hello):
            guard let display = hello.displays.first else { return }
            displays = hello.displays
            activeDisplayID = display.id
            displaySize = Self.size(of: display)
            isStreaming = true
        case .videoFrame(let frame):
            // The frame self-describes the region it shows; settle the residual zoom to it. The
            // loop applies this only after a successful decode — a frame that failed to decode
            // must not move the viewport.
            settleViewport(to: CGRect(x: frame.normalizedViewportX, y: frame.normalizedViewportY,
                                      width: frame.normalizedViewportW, height: frame.normalizedViewportH))
        case .cursorPosition(let cursor):
            // Guard like `frameViewport`: a confirmation that matches the local prediction
            // (the common case during a drag) must not re-write `cursorNormalized`, or it
            // re-targets the cursor-follow spring every report for no visible motion.
            let p = CGPoint(x: cursor.normalizedX, y: cursor.normalizedY)
            if !p.isClose(to: cursorNormalized) { cursorNormalized = p }
        case .displaysUpdate(let update):
            // The host re-advertised its displays (a monitor connected/woke/was removed).
            displays = update.displays
            let resolved = DisplaySelection.resolvedActiveDisplay(current: activeDisplayID, among: update.displays)
            if resolved != activeDisplayID, let display = update.displays.first(where: { $0.id == resolved }) {
                // The streamed display went away — retarget to the fallback, resetting the
                // cursor/viewport for the new display (as a user-initiated switch does).
                activeDisplayID = resolved
                displaySize = Self.size(of: display)
                cursorNormalized = CGPoint(x: 0.5, y: 0.5)
                frameViewport = CGRect(x: 0, y: 0, width: 1, height: 1)
            } else if let active = update.displays.first(where: { $0.id == activeDisplayID }) {
                // Same active display; track a resolution change so the zoom geometry stays correct.
                let size = Self.size(of: active)
                if size != displaySize { displaySize = size }
            }
        case .hostLockStatus(let lock):
            // The host's screen locked/unlocked. Guard so an unchanged state isn't a delta.
            if lock.locked != hostLocked { hostLocked = lock.locked }
        case .viewport(let v):
            // Defensive fallback: the host now embeds the region in every VideoFrame, so it no
            // longer sends standalone `.viewport` echoes — but honor one if it arrives.
            settleViewport(to: CGRect(x: v.normalizedX, y: v.normalizedY,
                                      width: v.normalizedW, height: v.normalizedH))
        default:
            break  // effect-only messages (decode/audio/files/clipboard/control) stay in the session loop
        }
    }

    /// Guard the assignment so an unchanged region (steady state — the quantized value is
    /// bit-identical) isn't a delta the view model would publish ~60×/s.
    private mutating func settleViewport(to region: CGRect) {
        if region != frameViewport { frameViewport = region }
    }

    private static func size(of display: DisplayInfo) -> CGSize {
        CGSize(width: max(1, Double(display.width)), height: max(1, Double(display.height)))
    }
}

public extension CGPoint {
    /// Two normalized cursor positions are "the same" within sub-pixel epsilon. Used to skip a host
    /// cursor confirmation that already matches the local prediction: applying it would re-target the
    /// cursor-follow spring for no visible movement, so we drop it (the prediction already moved us).
    func isClose(to other: CGPoint, epsilon: CGFloat = 0.001) -> Bool {
        abs(x - other.x) < epsilon && abs(y - other.y) < epsilon
    }
}
