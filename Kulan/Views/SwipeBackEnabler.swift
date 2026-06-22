import SwiftUI
import UIKit

// We hide the navigation bar to draw our own flat header (so iOS 26 can't wrap it
// in a Liquid-Glass pill). Hiding the bar normally KILLS the edge swipe-back
// gesture — this re-enables it by re-attaching the interactive pop recognizer.
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
        // Only allow the swipe when there's something to pop back to.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
