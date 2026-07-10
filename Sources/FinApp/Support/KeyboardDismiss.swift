import SwiftUI
import UIKit

enum Keyboard {
    /// Resign the first responder app-wide, dismissing the keyboard.
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}

/// Attaches a tap recognizer to the key window so tapping anywhere outside a
/// text field dismisses the keyboard. `cancelsTouchesInView = false` keeps
/// buttons, list rows, and other controls fully responsive.
struct KeyboardDismisser: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window, context.coordinator.recognizer == nil else { return }
            let tap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.dismissKeyboard)
            )
            tap.cancelsTouchesInView = false
            tap.requiresExclusiveTouchType = false
            window.addGestureRecognizer(tap)
            context.coordinator.recognizer = tap
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var recognizer: UITapGestureRecognizer?

        @objc func dismissKeyboard() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
    }
}

/// Restores keyboard room for screens under the RootView pager, which ignores
/// the keyboard safe area (deliberate: keyboard resize shifted paging offsets).
/// Pads the bottom by the keyboard's height so content can scroll clear of the
/// keyboard; `KeyboardReveal` performs the actual scroll.
private struct KeyboardAvoidance: ViewModifier {
    @State private var keyboardHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, keyboardHeight)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { return }
                // +12 matches KeyboardReveal's gap above the keyboard so that
                // offset stays within the scrollable range.
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = frame.height + 12 }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
            }
    }
}

extension View {
    func keyboardAvoiding() -> some View { modifier(KeyboardAvoidance()) }
}

/// Scrolls a List row above the keyboard when it appears. Needed because the
/// RootView pager ignores the keyboard safe area, which also disables SwiftUI's
/// automatic focus scroll, and ScrollViewReader.scrollTo is a no-op inside
/// List. Place as a `.background` of the text field's row content; pair with
/// `keyboardAvoiding()` on the List so there is room to scroll into.
struct KeyboardReveal: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Marker() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Marker: UIView {
        private var observers: [NSObjectProtocol] = []
        private var keyboardTop: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
                return
            }
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { return }
                self?.keyboardTop = frame.minY
                // Let the keyboard-show and safe-area-padding animations settle
                // before measuring the overlap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.reveal() }
            })
            observers.append(center.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.keyboardTop = nil
            })
        }

        // The multi-line field grows while typing; keep it above the keyboard.
        override func layoutSubviews() {
            super.layoutSubviews()
            if keyboardTop != nil { reveal() }
        }

        private func reveal() {
            guard let keyboardTop, let window else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UICollectionView) { ancestor = view.superview }
            guard let collectionView = ancestor as? UICollectionView else { return }
            let fieldBottom = convert(bounds, to: window).maxY
            let overlap = fieldBottom + 12 - keyboardTop
            guard overlap > 1 else { return }
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x,
                        y: collectionView.contentOffset.y + overlap),
                animated: true
            )
        }
    }
}
