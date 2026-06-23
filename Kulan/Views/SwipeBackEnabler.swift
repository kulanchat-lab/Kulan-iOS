import SwiftUI
import UIKit

// The chat header lives in the view body (so it slides 1:1 with the swipe like
// Signal). That requires hiding the nav bar, which disables iOS's edge swipe-back.
// This restores it by re-enabling the interactive pop recognizer and clearing its
// delegate (the standard fix). Runs at multiple lifecycle points + walks the VC
// tree to reliably find the UINavigationController.
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Proxy() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {
        (vc as? Proxy)?.restore()
    }

    final class Proxy: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent); restore()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated); restore()
        }

        func restore() {
            DispatchQueue.main.async { [weak self] in
                guard let nav = self?.findNav() else { return }
                nav.interactivePopGestureRecognizer?.isEnabled = true
                nav.interactivePopGestureRecognizer?.delegate = self
            }
        }

        private func findNav() -> UINavigationController? {
            if let n = navigationController { return n }
            var node: UIViewController? = parent
            while let cur = node {
                if let n = cur as? UINavigationController { return n }
                if let n = cur.navigationController { return n }
                node = cur.parent
            }
            // Last resort: walk down from the key window's root.
            return Self.search(UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
                .first { $0.isKeyWindow }?.rootViewController)
        }

        private static func search(_ vc: UIViewController?) -> UINavigationController? {
            guard let vc else { return nil }
            if let n = vc as? UINavigationController { return n }
            for child in vc.children { if let n = search(child) { return n } }
            return search(vc.presentedViewController)
        }

        // Allow the swipe only when there's something to pop back to.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (findNav()?.viewControllers.count ?? 0) > 1
        }
    }
}
