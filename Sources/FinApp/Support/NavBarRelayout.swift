import SwiftUI
import UIKit

/// Restores the large navigation title's leading inset whenever `trigger` changes.
///
/// The five tab screens live in an eager `HStack` inside RootView's horizontal
/// pager, so their `NavigationStack`s' `UINavigationBar`s sit side by side in the
/// scroll content. UIKit then mis-derives each bar's `directionalLayoutMargins`
/// from the window safe area and leaves some with a `leading` of 0 instead of the
/// standard 16, which pins the large title flush-left until a manual scroll forces
/// a recompute. Re-asserting the leading margin on tab arrival fixes it without the
/// scroll. Two passes (immediate + after the paging animation settles) cover the
/// case where the system recomputes the margin to 0 mid-transition.
struct NavBarRelayout: UIViewControllerRepresentable {
    /// Standard large-title leading inset on iPhone (matches the List row inset).
    private static let leadingInset: CGFloat = 16

    let trigger: Int

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        for delay in [0.0, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let bar = controller.navigationController?.navigationBar else { return }
                if bar.directionalLayoutMargins.leading < Self.leadingInset {
                    bar.directionalLayoutMargins.leading = Self.leadingInset
                    bar.setNeedsLayout()
                    bar.layoutIfNeeded()
                }
            }
        }
    }

    final class Controller: UIViewController {}
}

extension View {
    /// Restores the large navigation title's leading inset on tab arrival (see
    /// `NavBarRelayout`). Pass the screen's `topReset` token.
    func fixLargeTitleInset(trigger: Int) -> some View {
        background(NavBarRelayout(trigger: trigger))
    }
}
