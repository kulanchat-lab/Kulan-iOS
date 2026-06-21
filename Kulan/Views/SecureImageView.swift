import SwiftUI
import UIKit

// Downloads the encrypted bytes and decrypts them locally (the server only ever
// stored ciphertext). Shows a placeholder while loading.
struct SecureImageView: View {
    let imageUrl: String
    let enc: EncMeta?
    let cid: String

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
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
        guard image == nil, let url = URL(string: imageUrl) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let enc {
                if let clear = await Crypto.shared.decryptBytes(cid, cipher: data, meta: enc),
                   let ui = UIImage(data: clear) {
                    image = ui
                } else { failed = true }
            } else if let ui = UIImage(data: data) {
                image = ui
            } else { failed = true }
        } catch {
            failed = true
        }
    }
}
