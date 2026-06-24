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
