import SwiftUI
import UIKit
import Photos

// Full-screen photo viewer (Telegram-style): pinch to zoom, drag down to dismiss.
struct ImageViewerView: View {
    let message: Message
    let cid: String
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var dragOffset: CGSize = .zero
    @State private var saved = false
    @State private var saveError = false

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(Double(abs(dragOffset.height)) / 400, 0.6)).ignoresSafeArea()

            if let url = message.imageUrl {
                SecureImageView(imageUrl: url, enc: message.enc, cid: cid, fill: false)
                    .scaleEffect(scale)
                    .offset(dragOffset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = max(1, $0) }
                            .onEnded { _ in withAnimation(.spring) { scale = max(1, scale) } }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in if scale <= 1.01 { dragOffset = v.translation } }
                            .onEnded { v in
                                if abs(v.translation.height) > 120 { dismiss() }
                                else { withAnimation(.spring) { dragOffset = .zero } }
                            }
                    )
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .liquidGlass(Circle(), interactive: true)
                    }
                    Spacer()
                    Button { save() } label: {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.title3.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: saved)
                            .foregroundStyle(.white)
                            .padding(12)
                            .liquidGlass(Circle(), interactive: true)
                    }
                    .disabled(saved)
                }
                .padding()
                Spacer()
            }
        }
        .alert("Couldn't save photo", isPresented: $saveError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Check Photos permission and try again.") }
    }

    // Save the decrypted image to the camera roll — disk fallback + REAL success/failure.
    private func save() {
        Task {
            var ui = message.imageUrl.flatMap { DiskImageCache.shared.memoryImage($0) }
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
