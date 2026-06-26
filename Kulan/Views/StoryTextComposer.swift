import SwiftUI

// Text story (Instagram/WhatsApp-style): a gradient background + centered text, rendered
// to a 9:16 image and posted through the SAME story pipeline as a photo. Tap the palette
// to cycle backgrounds; type; Share. No new backend — it's just an image.
struct StoryTextComposer: View {
    var onShare: (Data) -> Void
    var onClose: () -> Void

    @State private var text = ""
    @State private var bgIndex = 0
    @FocusState private var focused: Bool

    private let backgrounds: [[Color]] = [
        [Color(hex: 0x7F00FF), Color(hex: 0xE100FF)],
        [Color(hex: 0xFF512F), Color(hex: 0xDD2476)],
        [Color(hex: 0x11998E), Color(hex: 0x38EF7D)],
        [Color(hex: 0x2193B0), Color(hex: 0x6DD5ED)],
        [Color(hex: 0xF7971E), Color(hex: 0xFFD200)],
        [Color(hex: 0x141E30), Color(hex: 0x243B55)],
        [Color(hex: 0x0F2027), Color(hex: 0x2C5364)],
    ]
    private func gradient(_ i: Int) -> LinearGradient {
        LinearGradient(colors: backgrounds[i % backgrounds.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ZStack {
                // Full-bleed gradient background.
                gradient(bgIndex).ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.35), value: bgIndex)   // smooth background cycle

                // Centered editable text — .plain removes the iOS default white box.
                ZStack {
                    if text.isEmpty {
                        Text("Type something…")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $text, axis: .vertical)
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .textFieldStyle(.plain)          // prevents the system white-box background
                        .background(Color.clear)
                        .padding(.horizontal, 28)
                }

                // Top controls: close (X) left, palette right.
                VStack {
                    HStack {
                        Button(action: onClose) { circle("xmark") }.buttonStyle(.plain)
                        Spacer()
                        Button { bgIndex += 1 } label: { circle("paintpalette.fill") }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                    Spacer()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Native keyboard accessory: Share docks directly above the keyboard and tracks it.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { share() } label: {
                        Label("Share to My Status", systemImage: "paperplane.fill").fontWeight(.semibold)
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .onAppear { focused = true }
    }

    // Render the gradient + text to a 1080×1920 JPEG and hand it to the poster.
    @MainActor private func share() {
        guard !trimmed.isEmpty else { return }
        let card = ZStack {
            gradient(bgIndex)
            Text(trimmed)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
                .padding(80)
        }
        .frame(width: 1080, height: 1920)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        if let ui = renderer.uiImage, let data = ui.jpegData(compressionQuality: 0.9) {
            focused = false
            onShare(data)
        }
    }

    private func circle(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())   // native system material
    }
}
