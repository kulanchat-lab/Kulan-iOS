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
    let showMore: Bool                    // show the header "…" dropdown menu
    let onDragChanged: (CGFloat) -> Void   // overlay fade only; the card itself moves in UIKit (smooth)
    let onCommit: () -> Void               // pulled past threshold -> dismiss
    let onCancel: () -> Void               // released short -> overlays restore
    let onSwipeUp: () -> Void              // up-swipe -> host opens the views sheet (Telegram)

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.view.backgroundColor = .black   // solid card; slides as one unit during dismiss
        // Telegram: the story is a rounded card on black (12pt continuous corners) at rest.
        pager.view.layer.cornerRadius = 12
        pager.view.layer.cornerCurve = .continuous
        pager.view.layer.masksToBounds = true
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

    // CADisplayLink retains its target (the coordinator), and the run loop retains the link, so deinit
    // never runs on its own -> leak + a per-frame wakeup that lives forever. Tear it down explicitly when
    // SwiftUI dismantles the representable (story closed).
    static func dismantleUIViewController(_ uiViewController: UIPageViewController, coordinator: Coordinator) {
        coordinator.cubeLink?.invalidate()
        coordinator.cubeLink = nil
    }

    // Telegram's cube transform (sideAngle = 0): perspective m34 = -1/500, Y-rotation up to 90°, plus the
    // cube-distance depth so the two faces meet at the shared edge, and a face push (+w/2 z) so the centred
    // page sits flat at full size (cancels the -w/2). t in [-1, 1]: 0 = flat centre, ±1 = edge-on.
    static func cubeTransform(_ t: CGFloat, width w: CGFloat) -> CATransform3D {
        let tc = max(-1, min(1, t))
        let absT = abs(tc)
        let angle = tc * (.pi / 2)
        let cubeDistance = 0.5 * w * (1.4142135623731 * sin((.pi / 2) * absT + .pi / 4) - 1.0)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1.0 / 500.0
        var t3d = CATransform3DTranslate(perspective, 0, 0, -w * 0.5)
        t3d = CATransform3DTranslate(t3d, 0, 0, -cubeDistance)
        t3d = CATransform3DConcat(CATransform3DMakeRotation(angle, 0, 1, 0), t3d)
        let face = CATransform3DMakeTranslation(0, 0, w * 0.5)
        return CATransform3DConcat(face, t3d)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        let parent: StoryPager
        weak var pager: UIPageViewController?
        weak var internalScroll: UIScrollView?
        private var didInstallPan = false
        fileprivate var cubeLink: CADisplayLink?   // fileprivate so dismantleUIViewController can invalidate it

        init(_ parent: StoryPager) { self.parent = parent }
        deinit { cubeLink?.invalidate() }

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
                onItemSeen: parent.onItemSeen,
                showMore: parent.showMore
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
            internalScroll = scroll
            let pan = DirectionalPanGestureRecognizer(direction: .down, target: self, action: #selector(handleDismiss(_:)))
            pan.delegate = self
            pager.view.addGestureRecognizer(pan)
            scroll?.panGestureRecognizer.require(toFail: pan)
            // Up-swipe opens the views sheet (Telegram). Direction-locked so it never fights the cube or dismiss.
            let upPan = DirectionalPanGestureRecognizer(direction: .up, target: self, action: #selector(handleSwipeUp(_:)))
            upPan.delegate = self
            pager.view.addGestureRecognizer(upPan)
            scroll?.panGestureRecognizer.require(toFail: upPan)
            // Drive Telegram's cube every frame from the pager scroll offset.
            let link = CADisplayLink(target: self, selector: #selector(applyCube))
            link.add(to: .main, forMode: .common)
            cubeLink = link
        }

        // Telegram's cube: rotate each page around the shared vertical edge with perspective depth, driven
        // by its position relative to screen centre. Centre page = flat; ±1 page = 90° (edge-on, hidden).
        @objc func applyCube() {
            guard let scroll = internalScroll else { return }
            // Only do per-frame transform work while a horizontal swipe is actually in motion. At rest the
            // pages are already settled (centred page = identity from the last frame), so skip the churn.
            guard scroll.isDragging || scroll.isDecelerating || scroll.isTracking else { return }
            let w = scroll.bounds.width
            guard w > 1 else { return }
            for sub in scroll.subviews {
                guard abs(sub.bounds.width - w) < 1.0 else { continue }   // page-sized views only
                let t = (sub.frame.minX - scroll.contentOffset.x) / w     // 0 = centred
                sub.layer.isDoubleSided = false                            // hide the back face
                if abs(t) < 0.001 {
                    sub.layer.transform = CATransform3DIdentity            // resting page is pixel-perfect
                } else if abs(t) <= 1.0 {
                    sub.layer.transform = StoryPager.cubeTransform(t, width: w)
                }
            }
        }

        @objc func handleDismiss(_ g: UIPanGestureRecognizer) {
            guard let pager else { return }
            let v = pager.view!
            let t = g.translation(in: v)
            switch g.state {
            case .began:
                NotificationCenter.default.post(name: .pauseStory, object: nil)   // freeze for the whole drag
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
                    NotificationCenter.default.post(name: .resumeStory, object: nil)   // sprang back -> resume
                    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85,
                                   initialSpringVelocity: 0.3, options: []) {
                        v.transform = .identity
                        v.layer.cornerRadius = 12   // back to the resting rounded-card corner
                    } completion: { _ in self.parent.onCancel() }
                }
            default: break
            }
        }
        @objc func handleSwipeUp(_ g: UIPanGestureRecognizer) {
            guard let pager else { return }
            let t = g.translation(in: pager.view)
            let v = g.velocity(in: pager.view)
            if g.state == .ended, t.y < -90 || v.y < -600 { parent.onSwipeUp() }
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
