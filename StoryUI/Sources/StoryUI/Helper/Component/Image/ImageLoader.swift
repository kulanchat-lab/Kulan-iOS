//
//  ImageLoader.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Combine
import UIKit
import CryptoKit

// Persistent disk cache for story images — survives app relaunches (unlike URLCache, which evicts).
// Keyed by a STABLE hash of the URL path (String.hashValue is randomized per process, so unusable;
// we ignore the volatile Firebase ?token query so the same file always maps to the same file on disk).
enum StoryDiskCache {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("StoryImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static func key(_ url: URL) -> String {
        let base = (url.scheme ?? "") + (url.host ?? "") + url.path
        let digest = Insecure.MD5.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func path(_ url: URL) -> URL { dir.appendingPathComponent(key(url)) }
    static func image(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: path(url)) else { return nil }
        return UIImage(data: data)
    }
    static func store(_ data: Data, for url: URL) {
        try? data.write(to: path(url), options: .atomic)
    }
}

// Shimmering skeleton placeholder (instead of a spinner) while an image is fetched — feels faster.
final class ShimmerView: UIView {
    private let gradient = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.14, alpha: 1)
        let dark = UIColor(white: 0.14, alpha: 1).cgColor
        let light = UIColor(white: 0.26, alpha: 1).cgColor
        gradient.colors = [dark, light, dark]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.5, 1]
        layer.addSublayer(gradient)
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-1.0, -0.5, 0.0]
        anim.toValue = [1.0, 1.5, 2.0]
        anim.duration = 1.15
        anim.repeatCount = .infinity
        gradient.add(anim, forKey: "shimmer")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds }
}

final class ImageLoader: UIView {

    // MARK: Public Properties
    var imageURL: URL?
    // Foreground: the photo at its TRUE aspect ratio — never stretched/cropped (Instagram/WhatsApp).
    var imageView = UIImageView()
    // Background: a zoomed + blurred copy of the same photo that fills the empty top/bottom.
    private let backgroundImageView = UIImageView()
    // Telegram glass mirror: a THIN dark frosted blur so the blurred copy of the image is VISIBLE behind the
    // bars (the thick material looked solid black). A subtle dark tint keeps it from distracting.
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let darkTint = UIView()
    private let shimmer = ShimmerView()

    // MARK: - Initializers
    init() {
        super.init(frame: .zero)
        setupImageView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundImageView.frame = bounds
        blurView.frame = bounds
        darkTint.frame = bounds
        imageView.frame = bounds
        shimmer.frame = bounds
    }

    private func apply(_ image: UIImage?) {
        imageView.image = image
        backgroundImageView.image = image
    }

    private func showShimmer(_ show: Bool) {
        shimmer.isHidden = !show
        if show { bringSubviewToFront(shimmer) }
    }

    func loadImageWithUrl(_ url: String?, imageIsLoaded: @escaping () -> Void) {

        guard let validatedUrl = url else {
            print("url error")
            return
        }

        if imageURL == URL(string: validatedUrl) {
            return
        }

        imageURL = URL(string: validatedUrl)

        guard let imageURL else { return }

        // stop video if it's playing before image request
        NotificationCenter.default.post(name: .stopVideo, object: nil)

        // 1) Memory (URLCache) — instant.
        if let cachedResponse = URLCache.shared.cachedResponse(for: .init(url: imageURL)),
           let img = UIImage(data: cachedResponse.data) {
            DispatchQueue.main.async { [weak self] in
                self?.showShimmer(false)
                self?.apply(img)
                imageIsLoaded()
            }
            return
        }

        // 2) Disk — instant on revisit / relaunch (persistent, the big-apps behaviour).
        if let disk = StoryDiskCache.image(imageURL) {
            DispatchQueue.main.async { [weak self] in
                self?.showShimmer(false)
                self?.apply(disk)
                imageIsLoaded()
            }
            return
        }

        // 3) Network — show the shimmer skeleton (not a spinner) while it downloads.
        apply(nil)
        showShimmer(true)

        let requestedURL = imageURL   // capture: if the view is reused mid-download, drop this stale result
        URLSession.shared.dataTask(
            with: imageURL,
            completionHandler: { [weak self] (data, response, error) in
            guard let self else { return }
            if error != nil {
                print(error as Any)
                DispatchQueue.main.async { self.showShimmer(false); imageIsLoaded() }
                return
            }

            guard let data,
                  let response,
                  let image = UIImage(data: data)
            else {
                DispatchQueue.main.async { self.showShimmer(false); imageIsLoaded() }
                return
            }

            URLCache.shared.storeCachedResponse(.init(response: response, data: data), for: .init(url: imageURL))
            StoryDiskCache.store(data, for: imageURL)   // persist to disk → instant next time

            DispatchQueue.main.async {
                self.showShimmer(false)
                guard self.imageURL == requestedURL else { imageIsLoaded(); return }   // reused → don't show stale photo
                self.apply(image)
                imageIsLoaded()
            }
        }).resume()
    }

}
// MARK: - Private Funcs
private extension ImageLoader {
   func setupImageView() {
       backgroundColor = .black
       // WhatsApp/Instagram for non-9:16 photos: a zoomed + heavily-blurred copy of the SAME image fills the
       // whole screen behind, so the empty top/bottom become a blurred color-matched backdrop (no black bars).
       backgroundImageView.contentMode = .scaleAspectFill
       backgroundImageView.clipsToBounds = true
       addSubview(backgroundImageView)
       addSubview(blurView)   // frosted blur over the fill copy (Telegram glass mirror)
       darkTint.backgroundColor = UIColor.black.withAlphaComponent(0.22)   // subtle dark tint over the blur
       darkTint.isUserInteractionEnabled = false
       addSubview(darkTint)

       // Foreground: the photo at its TRUE aspect ratio — aspect-FIT so a square/landscape is never cropped.
       imageView.contentMode = .scaleAspectFit
       imageView.clipsToBounds = true
       addSubview(imageView)

       shimmer.isHidden = true
       addSubview(shimmer)
   }
}
