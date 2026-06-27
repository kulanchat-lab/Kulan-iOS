import SwiftUI
import PencilKit
import CoreImage
import CoreImage.CIFilterBuiltins

// In-chat photo editor (WhatsApp-style): the picked image fills the screen with a caption bar
// and a tool row — crop (aspect), pen (draw), light (adjust filters), HD (full-quality). On send
// the edits are flattened into one image and handed back via onSend (+ an optional caption).
// Every button is real. Reuses DrawingCanvas (defined in StoryEditorView.swift).
struct ChatImageEditor: View {
    let source: UIImage
    var onSend: (_ image: Data, _ caption: String, _ hd: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var drawing = PKDrawing()
    @State private var isDrawing = false
    @State private var filterIndex = 0
    @State private var aspectIndex = 0
    @State private var hd = false
    @State private var canvasSize: CGSize = .zero
    @FocusState private var captionFocused: Bool

    private static let ctx = CIContext()
    private static let filters: [(String, String?)] = [
        ("Original", nil), ("Vivid", "CIPhotoEffectChrome"), ("Mono", "CIPhotoEffectMono"),
        ("Fade", "CIPhotoEffectFade"), ("Noir", "CIPhotoEffectNoir"),
    ]
    private static let aspects: [(String, CGFloat?)] = [("Original", nil), ("Square", 1), ("Portrait", 4.0/5.0)]

    private var edited: UIImage { Self.cropped(Self.filtered(source, filterIndex), aspect: Self.aspects[aspectIndex].1) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: edited)
                    .resizable().scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                if isDrawing {
                    DrawingCanvas(drawing: $drawing, isActive: true).ignoresSafeArea()
                }

                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 48, height: 48).background(.black.opacity(0.4), in: Circle())
                        }
                        Spacer()
                        if isDrawing {
                            Button("Done") { isDrawing = false }.foregroundStyle(.white).fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, geo.safeAreaInsets.top + 6)
                    Spacer()
                    bottomBar
                        .padding(.bottom, geo.safeAreaInsets.bottom + 8)
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, s in canvasSize = s }
        }
        .statusBarHidden()
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // Caption capsule — dark pill, same as Image 2.
            HStack(spacing: 10) {
                Image(systemName: "plus.square.on.square").foregroundStyle(.white)
                TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)))
                    .foregroundStyle(.white).focused($captionFocused)
                Image(systemName: "at").foregroundStyle(.white)
            }
            .padding(.horizontal, 16).frame(height: 46)
            .background(Color(white: 0.13), in: Capsule())

            // Tool row + send — Telegram-style: flat individual icons, no pill container.
            HStack(spacing: 0) {
                tool("crop", active: aspectIndex != 0) {
                    aspectIndex = (aspectIndex + 1) % Self.aspects.count
                }
                tool(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", active: isDrawing) {
                    isDrawing.toggle()
                }
                tool("slider.horizontal.3", active: filterIndex != 0) {
                    filterIndex = (filterIndex + 1) % Self.filters.count
                }
                tool("", active: hd, label: "HD") { hd.toggle() }

                Spacer()

                Button { send() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Color(.systemGreen), in: Circle())
                        .shadow(color: Color(.systemGreen).opacity(0.5), radius: 8)
                }
                .buttonStyle(StoryPressStyle())
            }
        }
        .padding(.horizontal, 16)
    }

    // Flat individual tool button — no background circle, white icon, green when active.
    @ViewBuilder
    private func tool(_ icon: String, active: Bool, label: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let label, !label.isEmpty {
                    // "HD" badge: text in a rounded-rect border, like Telegram.
                    Text(label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(active ? .green : .white)
                        .padding(.horizontal, 5)
                        .frame(height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(active ? Color.green : Color.white, lineWidth: 1.5)
                        )
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(active ? .green : .white)
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(StoryPressStyle())
    }

    private func send() {
        let data = flatten()
        onSend(data, caption.trimmingCharacters(in: .whitespacesAndNewlines), hd)
        dismiss()
    }

    @MainActor private func flatten() -> Data {
        let base = edited
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        let composed = ZStack {
            Image(uiImage: base).resizable().scaledToFit().frame(width: size.width, height: size.height)
            if !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale)).resizable()
            }
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: composed); r.scale = UIScreen.main.scale
        let quality: CGFloat = hd ? 0.95 : 0.85
        return r.uiImage?.jpegData(compressionQuality: quality) ?? (base.jpegData(compressionQuality: quality) ?? Data())
    }

    // MARK: - Image ops
    private static func filtered(_ image: UIImage, _ idx: Int) -> UIImage {
        guard idx != 0, let name = filters[idx].1, let ci = CIImage(image: image),
              let f = CIFilter(name: name) else { return image }
        f.setValue(ci, forKey: kCIInputImageKey)
        guard let out = f.outputImage, let cg = ctx.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func cropped(_ image: UIImage, aspect: CGFloat?) -> UIImage {
        guard let aspect, let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var cw = w, ch = h
        if w / h > aspect { cw = h * aspect } else { ch = w / aspect }
        let rect = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
