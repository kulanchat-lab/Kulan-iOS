import SwiftUI
import UIKit
import CropViewController

// SwiftUI wrapper around TimOliver/TOCropViewController — the gold-standard iOS cropper
// (pinch-zoom, pan, rotation dial + 90°, aspect ratio presets, reset). We keep our editor flow;
// the crop button presents this. Returns the cropped UIImage to the editor.
struct TOCropView: UIViewControllerRepresentable {
    let image: UIImage
    var onDone: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CropViewController {
        let vc = CropViewController(image: image)
        vc.delegate = context.coordinator
        vc.aspectRatioPickerButtonHidden = false   // let the user pick ratios
        vc.resetAspectRatioEnabled = true
        vc.aspectRatioLockEnabled = false
        vc.toolbarPosition = .bottom
        vc.doneButtonTitle = "Done"
        vc.cancelButtonTitle = "Cancel"

        // Real Apple liquid glass behind the crop toolbar (the library ships a solid dark bar).
        if #available(iOS 26.0, *) {
            let tb = vc.toolbar
            tb.backgroundColor = .clear
            let glass = UIVisualEffectView(effect: UIGlassEffect())
            glass.isUserInteractionEnabled = false
            glass.translatesAutoresizingMaskIntoConstraints = false
            tb.insertSubview(glass, at: 0)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: tb.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: tb.trailingAnchor),
                glass.topAnchor.constraint(equalTo: tb.topAnchor),
                glass.bottomAnchor.constraint(equalTo: tb.bottomAnchor),
            ])
        }
        return vc
    }

    func updateUIViewController(_ vc: CropViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CropViewControllerDelegate {
        let parent: TOCropView
        init(_ parent: TOCropView) { self.parent = parent }

        func cropViewController(_ cropViewController: CropViewController,
                                didCropToImage image: UIImage,
                                withRect cropRect: CGRect, angle: Int) {
            parent.onDone(image)
        }
        func cropViewController(_ cropViewController: CropViewController, didFinishCancelled cancelled: Bool) {
            parent.onCancel()
        }
    }
}
