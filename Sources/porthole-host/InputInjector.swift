import Foundation
import CoreGraphics
import PortholeProtocol

/// Maps Porthole input messages to synthesized macOS input events via CGEvent.
/// Requires Accessibility permission to actually take effect. Tracks the cursor
/// position itself (trackpad-style relative movement) and clamps to the display.
final class InputInjector: @unchecked Sendable {
    private var position: CGPoint
    private let bounds: CGRect
    private var leftButtonDown = false
    private let sensitivity: CGFloat

    init(displayBounds: CGRect, sensitivity: CGFloat = 1.5) {
        self.bounds = displayBounds
        self.position = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        self.sensitivity = sensitivity
    }

    func handle(_ message: AnyMessage) {
        switch message {
        case .pointerMove(let m): movePointer(dx: CGFloat(m.dx), dy: CGFloat(m.dy))
        case .pointerButton(let m): button(m.button, down: m.isDown)
        case .scroll(let m): scroll(dx: m.dx, dy: m.dy)
        case .typeText(let m): typeText(m.text)
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
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: .left)?
            .post(tap: .cghidEventTap)
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
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    private func scroll(dx: Int32, dy: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        for character in text {
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
