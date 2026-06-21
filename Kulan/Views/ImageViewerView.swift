import SwiftUI

// Full-screen photo viewer (Telegram-style): pinch to zoom, drag down to dismiss.
struct ImageViewerView: View {
    let message: Message
    let cid: String
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(abs(dragOffset.height) / 400, 0.6)).ignoresSafeArea()

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
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
    }
}
