import Foundation
import CoreGraphics
import PortviewProtocol

/// Maps Portview input messages to synthesized macOS input events via CGEvent.
/// Requires Accessibility permission to actually take effect. Tracks the cursor
/// position itself (trackpad-style relative movement) and clamps to the display.
final class InputInjector: @unchecked Sendable {
    /// Host-side authority: when true, `handle(_:)` is a no-op no matter what a (possibly
    /// modified/hostile) client sends — the ONLY other gate is client-side UX, not a security
    /// boundary. Shared process-wide (not per-instance) so a single LockMonitor callback in
    /// HostRunner pauses every current AND future injector across every connected session; a
    /// fresh connection or display switch can't bypass it. NSLock-guarded to mirror this file's
    /// sibling `@unchecked Sendable` types (HostControl, CaptureEngine, KeepAwake).
    private static let pauseLock = NSLock()
    nonisolated(unsafe) private static var isPaused = false

    var paused: Bool {
        get { Self.paused }
        set { Self.paused = newValue }
    }

    /// Same flag, settable without an instance in hand (used by HostRunner to drive it from the
    /// LockMonitor callback, which fires before any per-connection injector exists).
    static var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return isPaused }
        set { pauseLock.lock(); isPaused = newValue; pauseLock.unlock() }
    }

    /// Posting boundary: every synthesized event leaves through this closure; the default posts
    /// to the real HID event tap. Tests MUST replace it — under an Accessibility-granted parent
    /// process (a terminal running `swift test`) real posts type/click into whatever app has
    /// focus on the dev machine.
    var postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    /// Called with the normalized (0…1) cursor position after it moves (throttled).
    var onCursorMoved: ((Double, Double) -> Void)?
    private var position: CGPoint
    private let bounds: CGRect
    private var leftButtonDown = false
    private var lastReported = CGPoint(x: -1_000, y: -1_000)
    private let sensitivity: CGFloat

    init(displayBounds: CGRect, sensitivity: CGFloat = 1.5) {
        self.bounds = displayBounds
        self.position = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        self.sensitivity = sensitivity
    }

    func handle(_ message: AnyMessage) {
        guard !paused else { return }
        switch message {
        case .pointerMove(let m): movePointer(dx: CGFloat(m.dx), dy: CGFloat(m.dy))
        case .pointerButton(let m): button(m.button, down: m.isDown)
        case .scroll(let m): scroll(dx: m.dx, dy: m.dy)
        case .typeText(let m): typeText(m.text)
        case .keyEvent(let m): pressKey(m)
        default: break
        }
    }

    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: Swift.min(Swift.max(point.x, bounds.minX), bounds.maxX),
            y: Swift.min(Swift.max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func movePointer(dx: CGFloat, dy: CGFloat) {
        position = Self.clamp(
            CGPoint(x: position.x + dx * sensitivity, y: position.y + dy * sensitivity),
            to: bounds
        )
        let type: CGEventType = leftButtonDown ? .leftMouseDragged : .mouseMoved
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: .left) {
            postEvent(event)
        }
        reportCursorIfMoved()
    }

    private func reportCursorIfMoved() {
        guard onCursorMoved != nil, bounds.width > 0, bounds.height > 0 else { return }
        guard abs(position.x - lastReported.x) >= 3 || abs(position.y - lastReported.y) >= 3 else { return }
        lastReported = position
        let nx = Double((position.x - bounds.minX) / bounds.width)
        let ny = Double((position.y - bounds.minY) / bounds.height)
        onCursorMoved?(nx, ny)
    }

    private func button(_ kind: PointerButtonKind, down: Bool) {
        let type: CGEventType
        let button: CGMouseButton
        switch kind {
        case .left:
            type = down ? .leftMouseDown : .leftMouseUp
            button = .left
            leftButtonDown = down
        case .right:
            type = down ? .rightMouseDown : .rightMouseUp
            button = .right
        case .other:
            type = down ? .otherMouseDown : .otherMouseUp
            button = .center
        }
        if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: button) {
            postEvent(event)
        }
    }

    private func scroll(dx: Int32, dy: Int32) {
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
            postEvent(event)
        }
    }

    private func typeText(_ text: String) {
        for character in text {
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            postEvent(down)
            postEvent(up)
        }
    }

    private func pressKey(_ event: KeyEvent) {
        let flags = Self.cgFlags(event.modifiers)
        switch event.key {
        case .special(let key):
            postKey(Self.virtualKeyCode(key), flags: flags)
        case .character(let character):
            if let code = Self.ansiKeyCode(for: character) {
                postKey(code, flags: flags)
            } else {
                // Unmapped key (e.g. a non-ANSI character). Fall back to unicode typing;
                // modifier flags won't reliably register as a shortcut, but the text still lands.
                typeText(character)
            }
        }
    }

    /// Post a key-down/key-up pair for a virtual keycode with modifier flags applied to both.
    private func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) {
            down.flags = flags
            postEvent(down)
        }
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) {
            up.flags = flags
            postEvent(up)
        }
    }

    static func cgFlags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    /// Virtual keycode for a single character on the ANSI/US layout (the physical key;
    /// case and symbols come from modifier flags). Returns nil for anything unmapped.
    static func ansiKeyCode(for character: String) -> CGKeyCode? {
        guard let ch = character.lowercased().first else { return nil }
        return switch ch {
        case "a": 0x00
        case "s": 0x01
        case "d": 0x02
        case "f": 0x03
        case "h": 0x04
        case "g": 0x05
        case "z": 0x06
        case "x": 0x07
        case "c": 0x08
        case "v": 0x09
        case "b": 0x0B
        case "q": 0x0C
        case "w": 0x0D
        case "e": 0x0E
        case "r": 0x0F
        case "y": 0x10
        case "t": 0x11
        case "1": 0x12
        case "2": 0x13
        case "3": 0x14
        case "4": 0x15
        case "6": 0x16
        case "5": 0x17
        case "=": 0x18
        case "9": 0x19
        case "7": 0x1A
        case "-": 0x1B
        case "8": 0x1C
        case "0": 0x1D
        case "]": 0x1E
        case "o": 0x1F
        case "u": 0x20
        case "[": 0x21
        case "i": 0x22
        case "p": 0x23
        case "l": 0x25
        case "j": 0x26
        case "'": 0x27
        case "k": 0x28
        case ";": 0x29
        case "\\": 0x2A
        case ",": 0x2B
        case "/": 0x2C
        case "n": 0x2D
        case "m": 0x2E
        case ".": 0x2F
        case "`": 0x32
        case " ": 0x31
        default: nil
        }
    }

    static func virtualKeyCode(_ key: SpecialKey) -> CGKeyCode {
        switch key {
        case .returnKey: 0x24
        case .delete: 0x33
        case .tab: 0x30
        case .escape: 0x35
        case .arrowLeft: 0x7B
        case .arrowRight: 0x7C
        case .arrowDown: 0x7D
        case .arrowUp: 0x7E
        }
    }
}
