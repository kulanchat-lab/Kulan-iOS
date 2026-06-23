import SwiftUI
import UIKit

// Shared in-memory cache of decrypted images, keyed by URL. Stops SecureImageView
// from re-downloading + re-running libsodium every time a bubble scrolls back on
// screen (the big scroll-smoothness + data-saving win).
enum DecryptedImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>(); c.countLimit = 200; return c
    }()
}

// Downloads the encrypted bytes and decrypts them locally (the server only ever
// stored ciphertext). Shows a placeholder while loading.
struct SecureImageView: View {
    let imageUrl: String
    let enc: EncMeta?
    let cid: String
    var fill: Bool = true

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                Rectangle().fill(Color.gray.opacity(0.18))
                    .overlay {
                        if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
                        else { ProgressView() }
                    }
            }
        }
        .task(id: imageUrl) { await load() }
    }

    private func load() async {
        guard image == nil else { return }
        // Cache hit → show instantly, no network or decrypt.
        if let cached = DecryptedImageCache.shared.object(forKey: imageUrl as NSString) {
            image = cached; return
        }
        guard let url = URL(string: imageUrl) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            var ui: UIImage?
            if let enc {
                if let clear = await Crypto.shared.decryptBytes(cid, cipher: data, meta: enc) { ui = UIImage(data: clear) }
            } else {
                ui = UIImage(data: data)
            }
            if let ui {
                DecryptedImageCache.shared.setObject(ui, forKey: imageUrl as NSString)
                image = ui
            } else { failed = true }
        } catch {
            failed = true
        }
    }
}
