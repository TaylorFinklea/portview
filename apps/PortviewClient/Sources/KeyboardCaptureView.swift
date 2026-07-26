// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit
import PortviewProtocol

struct KeyboardViewportTransition: Equatable {
    enum Curve: Equatable {
        case easeInOut
        case easeIn
        case easeOut
        case linear
        case systemKeyboard

        init(rawValue: Int) {
            switch rawValue {
            case 0: self = .easeInOut
            case 1: self = .easeIn
            case 2: self = .easeOut
            case 3: self = .linear
            default: self = .systemKeyboard
            }
        }
    }

    static let empty = KeyboardViewportTransition(
        keyboardIntersection: .zero, duration: 0, curve: .systemKeyboard)

    let keyboardIntersection: CGRect
    let duration: TimeInterval
    let curve: Curve

    func effectiveHeight(in bounds: CGRect) -> CGFloat {
        let obstruction = bounds.intersection(keyboardIntersection)
        guard !obstruction.isNull, !obstruction.isEmpty else { return bounds.height }
        return min(bounds.height, max(0, obstruction.minY - bounds.minY))
    }

    var animation: Animation? {
        guard duration > 0 else { return nil }
        switch curve {
        case .easeInOut: return Animation.easeInOut(duration: duration)
        case .easeIn: return Animation.easeIn(duration: duration)
        case .easeOut: return Animation.easeOut(duration: duration)
        case .linear: return Animation.linear(duration: duration)
        case .systemKeyboard: return Animation.smooth(duration: duration)
        }
    }
}

@MainActor
final class KeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onSpecial: ((SpecialKey) -> Void)?
    var onWindowAttachment: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowAttachment?()
    }

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
    let onViewportTransition: (KeyboardViewportTransition) -> Void

    @MainActor
    final class Coordinator {
        var isActive = false
        var onViewportTransition: (KeyboardViewportTransition) -> Void
        private var observerTokens: [NSObjectProtocol] = []

        init(onViewportTransition: @escaping (KeyboardViewportTransition) -> Void) {
            self.onViewportTransition = onViewportTransition
        }

        func registerObservers(for view: KeyInputView) {
            let center = NotificationCenter.default
            observerTokens = [
                center.addObserver(
                    forName: UIResponder.keyboardWillChangeFrameNotification,
                    object: nil,
                    queue: .main
                ) { [weak self, weak view] notification in
                    MainActor.assumeIsolated {
                        self?.handleChangeFrame(notification, view: view)
                    }
                },
                center.addObserver(
                    forName: UIResponder.keyboardWillHideNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    MainActor.assumeIsolated {
                        self?.onViewportTransition(Self.transition(from: notification, intersection: .zero))
                    }
                }
            ]
        }

        func updateResponder(_ view: KeyInputView) {
            guard view.window != nil else { return }
            if isActive {
                if !view.isFirstResponder { view.becomeFirstResponder() }
            } else if view.isFirstResponder {
                view.resignFirstResponder()
            }
        }

        func removeObservers() {
            for token in observerTokens {
                NotificationCenter.default.removeObserver(token)
            }
            observerTokens.removeAll()
        }

        private func handleChangeFrame(_ notification: Notification, view: KeyInputView?) {
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let window = view?.window else { return }
            let screen = notification.object as? UIScreen ?? window.screen
            let windowFrame = window.convert(frame, from: screen.coordinateSpace)
            let intersection = window.bounds.intersection(windowFrame)
            onViewportTransition(Self.transition(
                from: notification,
                intersection: intersection.isNull ? .zero : intersection))
        }

        private static func transition(
            from notification: Notification,
            intersection: CGRect
        ) -> KeyboardViewportTransition {
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                as? NSNumber)?.doubleValue ?? 0
            let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey]
                as? NSNumber)?.intValue ?? 7
            return KeyboardViewportTransition(
                keyboardIntersection: intersection,
                duration: duration,
                curve: .init(rawValue: curveRaw))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onViewportTransition: onViewportTransition)
    }

    func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onText = onText
        view.onSpecial = onSpecial
        view.onWindowAttachment = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.updateResponder(view)
        }
        context.coordinator.isActive = isActive
        context.coordinator.registerObservers(for: view)
        return view
    }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onText = onText
        view.onSpecial = onSpecial
        context.coordinator.onViewportTransition = onViewportTransition
        context.coordinator.isActive = isActive
        context.coordinator.updateResponder(view)
    }

    static func dismantleUIView(_ view: KeyInputView, coordinator: Coordinator) {
        coordinator.removeObservers()
        view.onWindowAttachment = nil
        if view.isFirstResponder { view.resignFirstResponder() }
    }
}
