// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import PortviewProtocol

/// An invisible first-responder that surfaces the system keyboard and forwards keystrokes:
/// printable text becomes `typeText`, and the keys `typeText` can't express become `SpecialKey`s.
final class KeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onSpecial: ((SpecialKey) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        switch text {
        case "\n": onSpecial?(.returnKey)
        case "\t": onSpecial?(.tab)
        default: onText?(text)
        }
    }

    func deleteBackward() {
        onSpecial?(.delete)
    }
}

struct KeyboardCaptureView: UIViewRepresentable {
    @Binding var isActive: Bool
    let onText: (String) -> Void
    let onSpecial: (SpecialKey) -> Void

    func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onText = onText
        view.onSpecial = onSpecial
        return view
    }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onText = onText
        view.onSpecial = onSpecial
        if isActive {
            if !view.isFirstResponder { view.becomeFirstResponder() }
        } else if view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}
