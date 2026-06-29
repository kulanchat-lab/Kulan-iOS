//
// Route A: UIKit UIPageViewController pager (replaces the SwiftUI TabView). The dismiss pan is added to
// the pager's OWN scroll view (a real direct subview) with require(toFail:), so cube (sideways) and
// dismiss (down) are mutually exclusive (Signal's StoryPageViewController mechanism). Each page hosts
// the existing SwiftUI StoryDetailView, so all the story logic (progress, reply, tap-advance) is reused.
// The cube fold itself is the existing rotation3DEffect inside StoryDetailView (reads its own position).
//

import SwiftUI
import UIKit

struct StoryPager: UIViewControllerRepresentable {
    @ObservedObject var viewModel: StoryViewModel
    @Binding var isPresented: Bool
    let userClosure: UserCompletionHandler?
    let onProfile: ((StoryUIUser) -> Void)?
    let onItemSeen: ((String) -> Void)?
    let onDragChanged: (CGFloat) -> Void   // overlay fade only; the card itself moves in UIKit (smooth)
    let onCommit: () -> Void               // pulled past threshold -> dismiss
    let onCancel: () -> Void               // released short -> overlays restore

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black   // solid card; slides as one unit during dismiss
        context.coordinator.pager = pager
        if let first = context.coordinator.makePage(for: viewModel.currentStoryUser) {
            pager.setViewControllers([first], direction: .forward, animated: false)
        }
        DispatchQueue.main.async { context.coordinator.installDismissPan() }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.syncIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        let parent: StoryPager
        weak var pager: UIPageViewController?
        private var didInstallPan = false

        init(_ parent: StoryPager) { self.parent = parent }

        private func index(of id: String) -> Int? {
            parent.viewModel.stories.firstIndex { $0.id == id }
        }

        func makePage(for id: String) -> StoryPageHostVC? {
            guard let idx = index(of: id) else { return nil }
            let model = parent.viewModel.stories[idx]
            let root = StoryDetailView(
                viewModel: parent.viewModel,
                model: model,
                isPresented: parent.$isPresented,
                userClosure: parent.userClosure,
                onProfile: parent.onProfile,
                onItemSeen: parent.onItemSeen
            )
            let vc = StoryPageHostVC(rootView: AnyView(root))
            vc.bucketID = id
            return vc
        }

        // Keep the visible page synced if currentStoryUser changes from outside the pager (e.g. tap-advance
        // off the end of a bucket sets the next user).
        func syncIfNeeded() {
            guard let pager else { return }
            let shown = (pager.viewControllers?.first as? StoryPageHostVC)?.bucketID
            // Initial population: stories/currentStoryUser weren't ready at makeUIViewController time
            // (startStory runs in .onAppear, after), so the pager came up empty -> black. Fill it now.
            if shown == nil {
                if let first = makePage(for: parent.viewModel.currentStoryUser) {
                    pager.setViewControllers([first], direction: .forward, animated: false)
                }
                return
            }
            guard shown != parent.viewModel.currentStoryUser,
                  let from = index(of: shown!), let to = index(of: parent.viewModel.currentStoryUser),
                  let target = makePage(for: parent.viewModel.currentStoryUser)
            else { return }
            pager.setViewControllers([target], direction: to > from ? .forward : .reverse, animated: true)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let cur = (vc as? StoryPageHostVC)?.bucketID, let i = index(of: cur), i > 0 else { return nil }
            return makePage(for: parent.viewModel.stories[i - 1].id)
        }
        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let cur = (vc as? StoryPageHostVC)?.bucketID, let i = index(of: cur),
                  i < parent.viewModel.stories.count - 1 else { return nil }
            return makePage(for: parent.viewModel.stories[i + 1].id)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let cur = (pvc.viewControllers?.first as? StoryPageHostVC)?.bucketID else { return }
            parent.viewModel.currentStoryUser = cur   // StoryView's onChange fires onUserChanged
        }

        // MARK: dismiss pan (down only) + require-to-fail on the pager's own scroll
        func installDismissPan() {
            guard !didInstallPan, let pager else { return }
            didInstallPan = true
            let scroll = pager.view.subviews.compactMap { $0 as? UIScrollView }.first
            let pan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
            pan.delegate = self
            pager.view.addGestureRecognizer(pan)
            scroll?.panGestureRecognizer.require(toFail: pan)
        }

        @objc func handleDismiss(_ g: UIPanGestureRecognizer) {
            guard let pager else { return }
            let v = pager.view!
            let t = g.translation(in: v)
            switch g.state {
            case .changed:
                let ty = max(0, t.y)
                let frac = min(1, ty / v.bounds.height)
                let scale = 1.0 - 0.4 * frac            // Telegram: card scales 1.0 -> 0.6 as you pull
                v.layer.cornerCurve = .continuous       // Apple squircle
                v.layer.cornerRadius = min(40, 12 + ty * 0.3)
                v.layer.masksToBounds = true
                v.transform = CGAffineTransform(translationX: 0, y: ty).scaledBy(x: scale, y: scale)
                parent.onDragChanged(ty)                // fade the host overlays
            case .ended, .cancelled:
                let ty = t.y, vy = g.velocity(in: v).y
                // Telegram commit: translation.y > 200 OR (translation.y > 5 AND velocity.y > 200)
                if ty > 200 || (ty > 5 && vy > 200) {
                    UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
                        v.transform = CGAffineTransform(translationX: 0, y: v.bounds.height).scaledBy(x: 0.6, y: 0.6)
                    } completion: { _ in self.parent.onCommit() }
                } else {
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                                   initialSpringVelocity: 0.3, options: []) {
                        v.transform = .identity
                        v.layer.cornerRadius = 0
                    } completion: { _ in self.parent.onCancel() }
                }
            default: break
            }
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { false }
    }
}

// Hosts one bucket's StoryDetailView; remembers which bucket it is for the dataSource lookups.
final class StoryPageHostVC: UIHostingController<AnyView> {
    var bucketID: String = ""
    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        view.backgroundColor = .clear
    }
    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
