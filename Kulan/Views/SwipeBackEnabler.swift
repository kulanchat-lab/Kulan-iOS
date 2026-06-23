import SwiftUI
import UIKit

// The chat header lives in the view body (not the toolbar) so it slides 1:1 with
// the messages during the edge swipe-back — exactly like Signal. That means the
// nav bar is hidden, which normally disables the interactive pop gesture; this
// re-enables it.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Proxy() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}

    final class Proxy: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let nav = navigationController else { return }
            nav.interactivePopGestureRecognizer?.delegate = self
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
