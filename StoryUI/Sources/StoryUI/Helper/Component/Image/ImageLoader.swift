//
//  ImageLoader.swift
//  StoryUI
//
//  Created by Tolga İskender on 28.03.2022.
//

import Combine
import UIKit

final class ImageLoader: UIView {

    // MARK: Public Properties
    var imageURL: URL?
    // Foreground: the photo at its TRUE aspect ratio — never stretched/cropped (Instagram/WhatsApp).
    var imageView = UIImageView()
    // Background: a zoomed + blurred copy of the same photo that fills the empty top/bottom
    // (instead of black bars). A full-screen photo covers it, so it reads as full-bleed.
    private let backgroundImageView = UIImageView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    let activityIndicator = UIActivityIndicatorView(style: .large)

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
        imageView.frame = bounds
        activityIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func apply(_ image: UIImage?) {
        imageView.image = image
        backgroundImageView.image = image
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

        apply(nil)
        // stop video if it's playing before image request
        NotificationCenter.default.post(name: .stopVideo, object: nil)

        if let cachedResponse = URLCache.shared.cachedResponse(for: .init(url: imageURL)) {
            DispatchQueue.main.async { [weak self] in
                self?.apply(UIImage(data: cachedResponse.data))
                imageIsLoaded()
            }
            return
        }

        addIndicator()

        URLSession.shared.dataTask(
            with: imageURL,
            completionHandler: { [weak self] (data, response, error) in
            guard let self else { return }
            if error != nil {
                print(error as Any)
                // Mark "ready" + stop the spinner so the progress timer advances/auto-skips
                // instead of freezing the whole viewer on a failed load.
                DispatchQueue.main.async { self.activityIndicator.stopAnimating(); imageIsLoaded() }
                return
            }

            guard let data,
                  let response,
                  let image = UIImage(data: data)
            else {
                DispatchQueue.main.async { self.activityIndicator.stopAnimating(); imageIsLoaded() }
                return
            }

            URLCache.shared.storeCachedResponse(
                .init(response: response, data: data),
                for: .init( url: imageURL)
            )

            DispatchQueue.main.async {
                self.apply(image)
                imageIsLoaded()
                self.activityIndicator.stopAnimating()
            }
        }).resume()
    }

}
// MARK: - Private Funcs
private extension ImageLoader {
   func setupImageView() {
       backgroundColor = .black
       // Blurred fill behind, photo (true aspect) in front.
       backgroundImageView.contentMode = .scaleAspectFill
       backgroundImageView.clipsToBounds = true
       addSubview(backgroundImageView)
       addSubview(blurView)

       imageView.contentMode = .scaleAspectFit   // NEVER stretch — show the real shape (IG/WhatsApp)
       imageView.clipsToBounds = true
       addSubview(imageView)
   }
}
// MARK: - Const funcs
extension ImageLoader {

    private func addIndicator() {
        activityIndicator.color = UIColor.lightGray.withAlphaComponent(0.7)
        addSubview(activityIndicator)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        activityIndicator.startAnimating()
    }
}
