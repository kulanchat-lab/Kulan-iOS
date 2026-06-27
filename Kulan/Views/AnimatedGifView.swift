import SwiftUI
import UIKit
import ImageIO

// Plays an animated GIF from a URL with zero third-party deps — decodes frames via ImageIO
// into an animated UIImage. Used in the GIF picker and in chat bubbles.
struct AnimatedGifView: UIViewRepresentable {
    let url: String

    private static let cache = NSCache<NSString, UIImage>()   // decoded animated GIFs, reused across instances

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.backgroundColor = UIColor.secondarySystemFill
        load(into: v, context.coordinator)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if context.coordinator.loadedURL != url { load(into: v, context.coordinator) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loadedURL: String? }

    private func load(into v: UIImageView, _ coord: Coordinator) {
        coord.loadedURL = url   // mark BEFORE loading so re-renders/updates don't re-download+re-decode
        guard let u = URL(string: url) else { return }
        if let cached = Self.cache.object(forKey: url as NSString) { v.image = cached; return }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            guard let data, let img = UIImage.animatedGif(data: data) else { return }
            Self.cache.setObject(img, forKey: url as NSString)
            DispatchQueue.main.async { v.image = img }
        }.resume()
    }
}

extension UIImage {
    static func animatedGif(data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var duration = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(delay, 0.02)
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}
