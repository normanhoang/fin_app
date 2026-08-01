import SwiftUI
import UIKit

enum PrivacyShieldState: Equatable {
    case hidden
    case privacy
    case lock

    static func resolve(isInactive: Bool, lockEnabled: Bool, unlocked: Bool) -> Self {
        if lockEnabled && !unlocked { return .lock }
        if isInactive { return .privacy }
        return .hidden
    }
}

/// Owns a second UIWindow above every sheet/full-screen cover. SwiftUI overlays
/// live below presentations, so privacy and lock protection must be window-level.
struct PrivacyShieldHost: UIViewRepresentable {
    let lock: AppLock
    let state: PrivacyShieldState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let marker = UIView(frame: .zero)
        marker.isUserInteractionEnabled = false
        context.coordinator.marker = marker
        return marker
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(state: state, lock: lock)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.hide()
    }

    @MainActor
    final class Coordinator {
        weak var marker: UIView?
        private weak var appWindow: UIWindow?
        private var shieldWindow: UIWindow?
        private var currentState: PrivacyShieldState = .hidden

        func update(state: PrivacyShieldState, lock: AppLock) {
            guard state != currentState || shieldWindow == nil else { return }
            currentState = state
            guard state != .hidden else {
                hide()
                return
            }
            guard let scene = marker?.window?.windowScene else {
                DispatchQueue.main.async { [weak self] in self?.update(state: state, lock: lock) }
                return
            }

            if shieldWindow == nil {
                appWindow = marker?.window
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                window.backgroundColor = UIColor(Color.appBackground)
                shieldWindow = window
            }

            let content: AnyView
            switch state {
            case .privacy:
                content = AnyView(SplashView().accessibilityIdentifier("privacyShield"))
            case .lock:
                content = AnyView(LockScreen().environment(lock))
            case .hidden:
                return
            }
            shieldWindow?.rootViewController = UIHostingController(rootView: content)
            shieldWindow?.isHidden = false
            if state == .lock { shieldWindow?.makeKey() }
        }

        func hide() {
            shieldWindow?.isHidden = true
            shieldWindow?.rootViewController = nil
            appWindow?.makeKey()
        }
    }
}
