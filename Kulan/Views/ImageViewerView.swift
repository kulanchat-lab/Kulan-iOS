import SwiftUI
import UIKit
import Photos

// Full-screen photo viewer. Zoom/pan run on a native UIScrollView (Photos-app grade):
// finger-glued pinch, zero jitter, elastic bounce, pan only when zoomed. Drag down (at rest) dismisses.
struct ImageViewerView: View {
    let message: Message
    let cid: String
    @Environment(\.dismiss) private var dismiss

    @State private var uiImage: UIImage?
    @State private var dim: Double = 1            // backdrop opacity (fades while dragging to dismiss)
    @State private var saved = false
    @State private var saveError = false

    var body: some View {
        ZStack {
            Color.black.opacity(dim).ignoresSafeArea()

            if let img = uiImage {
                ZoomableImageScrollView(image: img,
                                        onDismiss: { dismiss() },
                                        onDim: { dim = $0 })
                    .ignoresSafeArea()
            } else if let url = message.imageUrl {
                SecureImageView(imageUrl: url, enc: message.enc, cid: cid, fill: false)   // placeholder while it loads
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold)).foregroundStyle(.white)
                            .padding(12).liquidGlass(Circle(), interactive: true)
                    }
                    Spacer()
                    Button { save() } label: {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.title3.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: saved)
                            .foregroundStyle(.white)
                            .padding(12).liquidGlass(Circle(), interactive: true)
                    }
                    .disabled(saved)
                }
                .padding()
                Spacer()
            }
            .opacity(dim > 0.85 ? 1 : 0)   // hide chrome while dismissing
        }
        .task { await loadImage() }
        .alert("Couldn't save photo", isPresented: $saveError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Check Photos permission and try again.") }
    }

    private func loadImage() async {
        guard let u = message.imageUrl else { return }
        if let m = DiskImageCache.shared.memoryImage(u) { uiImage = m; return }
        uiImage = await DiskImageCache.shared.image(for: u)
    }

    // Save the decrypted image to the camera roll, with a real success/failure.
    private func save() {
        Task {
            var ui = uiImage
            if ui == nil, let u = message.imageUrl { ui = await DiskImageCache.shared.image(for: u) }
            guard let image = ui else { await MainActor.run { saveError = true }; return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { await MainActor.run { saveError = true }; return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                await MainActor.run {
                    withAnimation { saved = true }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run { saveError = true }
            }
        }
    }
}

// Native UIScrollView zoom/pan. min = fit (elastic bounce-back below it), max = 4x, double-tap to zoom,
// haptic tap at the min/max boundary, and a drag-down-to-dismiss that only runs when not zoomed.
struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage
    var onDismiss: () -> Void
    var onDim: (Double) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.bouncesZoom = true            // min/max set in layout from the image's fit scale
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.isUserInteractionEnabled = true
        iv.layer.minificationFilter = .trilinear      // smoother scaled rendering (Signal)
        iv.layer.magnificationFilter = .trilinear
        iv.layer.allowsEdgeAntialiasing = true
        iv.clipsToBounds = true
        scroll.addSubview(iv)
        context.coordinator.scrollView = scroll
        context.coordinator.imageView = iv

        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onDoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(dbl)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onDismissPan(_:)))
        pan.delegate = context.coordinator
        scroll.addGestureRecognizer(pan)
        context.coordinator.dismissPan = pan

        context.coordinator.haptic.prepare()
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.layoutImageIfNeeded()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let parent: ZoomableImageScrollView
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        weak var dismissPan: UIPanGestureRecognizer?
        let haptic = UIImpactFeedbackGenerator(style: .rigid)
        private var didLayout = false
        private var atMax = false
        private var atMin = true

        init(_ parent: ZoomableImageScrollView) { self.parent = parent }

        func layoutImageIfNeeded() {
            guard !didLayout, let scroll = scrollView, let iv = imageView, scroll.bounds.width > 0 else { return }
            let imgSize = iv.image?.size ?? scroll.bounds.size
            guard imgSize.width > 0, imgSize.height > 0 else { return }
            didLayout = true
            iv.frame = CGRect(origin: .zero, size: imgSize)   // true pixels; fit comes from minimumZoomScale
            scroll.contentSize = imgSize
            let fit = min(scroll.bounds.width / imgSize.width, scroll.bounds.height / imgSize.height)
            scroll.minimumZoomScale = fit
            scroll.maximumZoomScale = fit * 8                 // up to 8x fit (Signal)
            scroll.zoomScale = fit
            center(scroll)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center(scrollView)
            let s = scrollView.zoomScale
            if s >= scrollView.maximumZoomScale - 0.01 { if !atMax { atMax = true; haptic.impactOccurred() } } else { atMax = false }
            if s <= scrollView.minimumZoomScale + 0.01 { if !atMin { atMin = true; haptic.impactOccurred() } } else { atMin = false }
        }

        private func center(_ scroll: UIScrollView) {
            guard let iv = imageView else { return }
            let x = max(0, (scroll.bounds.width - iv.frame.width) / 2)
            let y = max(0, (scroll.bounds.height - iv.frame.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        @objc func onDoubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = scrollView, let iv = imageView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)   // toggle back to fit
            } else {
                let target = scroll.minimumZoomScale * 3      // ~3x fit, centered on the tap
                let p = g.location(in: iv)
                let w = scroll.bounds.width / target
                let h = scroll.bounds.height / target
                scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }

        // Drag-down-to-dismiss: only at min zoom, only when the drag is vertical-dominant.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === dismissPan, let scroll = scrollView, let pan = g as? UIPanGestureRecognizer else { return true }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 { return false }
            let v = pan.velocity(in: scroll)
            return v.y > 0 && abs(v.y) > abs(v.x)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func onDismissPan(_ g: UIPanGestureRecognizer) {
            guard let scroll = scrollView, scroll.zoomScale <= scroll.minimumZoomScale + 0.01 else { return }
            let t = g.translation(in: scroll)
            switch g.state {
            case .changed:
                let ty: CGFloat = max(0, t.y)
                scroll.transform = CGAffineTransform(translationX: t.x * CGFloat(0.4), y: ty)
                let progress: Double = min(1.0, Double(ty) / 400.0)
                parent.onDim(1.0 - progress * 0.7)
            case .ended, .cancelled:
                if t.y > 120 {
                    parent.onDismiss()
                } else {
                    UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                        scroll.transform = .identity
                    }
                    parent.onDim(1)
                }
            default: break
            }
        }
    }
}
