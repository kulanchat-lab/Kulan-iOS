import SwiftUI
import PencilKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Photo-story editor — matches the in-chat photo editor (image 212): the picked photo fits on a
// black canvas; X top-left; a caption bar + @ and a crop / draw / adjust / HD tool row at the
// bottom with a green send. Send flattens the edits and opens the audience sheet, which posts the
// story via StoriesService. Every tool is real.
struct StoryEditorView: View {
    let source: UIImage
    var onPosted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var drawing = PKDrawing()
    @State private var isDrawing = false
    @State private var filterIndex = 0
    @State private var aspectIndex = 0
    @State private var hd = false
    @State private var editedCache: UIImage?         // filtered+cropped; recomputed only on tool change
    @State private var canvasSize: CGSize = .zero
    @State private var posting = false
    @State private var postError = false
    @State private var pendingShare: StoryShareData?
    @FocusState private var captionFocused: Bool

    private static let ciContext = CIContext()
    private static let filters: [(name: String, ci: String?)] = [
        ("Original", nil), ("Vivid", "CIPhotoEffectChrome"), ("Mono", "CIPhotoEffectMono"),
        ("Fade", "CIPhotoEffectFade"), ("Noir", "CIPhotoEffectNoir"),
    ]
    private static let aspects: [(String, CGFloat?)] = [("Original", nil), ("Square", 1), ("Portrait", 4.0 / 5.0)]

    private var edited: UIImage { editedCache ?? source }
    private func recomputeEdited() {
        editedCache = Self.cropped(Self.apply(Self.filters[filterIndex].ci, to: source),
                                   aspect: Self.aspects[aspectIndex].1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                // Blurred fill behind (IG/WhatsApp), so a non-full-screen photo isn't on black bars.
                Image(uiImage: edited)
                    .resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped().blur(radius: 32).opacity(0.55)
                    .ignoresSafeArea()
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
            .onAppear { canvasSize = geo.size; recomputeEdited() }
            .onChange(of: geo.size) { _, s in canvasSize = s }
            .onChange(of: filterIndex) { _, _ in recomputeEdited() }
            .onChange(of: aspectIndex) { _, _ in recomputeEdited() }
        }
        .statusBarHidden()
        .alert("Couldn't share", isPresented: $postError) { Button("OK", role: .cancel) {} }
        .sheet(item: $pendingShare) { s in ShareStorySheet(image: s.data, onPosted: { onPosted(); dismiss() }) }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // Caption bar — dark pill, same as image 212.
            HStack(spacing: 10) {
                Image(systemName: "plus.square.on.square").foregroundStyle(.white)
                TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)))
                    .foregroundStyle(.white).focused($captionFocused)
                Image(systemName: "at").foregroundStyle(.white)
            }
            .padding(.horizontal, 16).frame(height: 46)
            .background(Color(white: 0.13), in: Capsule())

            // Tool row (crop · draw · adjust · HD) + green send — flat icons, like image 212.
            HStack(spacing: 0) {
                tool("crop", active: aspectIndex != 0) { aspectIndex = (aspectIndex + 1) % Self.aspects.count }
                tool(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", active: isDrawing) { isDrawing.toggle() }
                tool("slider.horizontal.3", active: filterIndex != 0) { filterIndex = (filterIndex + 1) % Self.filters.count }
                tool("", active: hd, label: "HD") { hd.toggle() }

                Spacer()

                Button { Task { await send() } } label: {
                    Image(systemName: posting ? "ellipsis" : "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 46, height: 46).background(Color(.systemGreen), in: Circle())
                        .shadow(color: Color(.systemGreen).opacity(0.5), radius: posting ? 2 : 8)
                }
                .buttonStyle(StoryPressStyle()).disabled(posting)
            }
        }
        .padding(.horizontal, 16)
    }

    // Flat tool button: white icon, green when active; "HD" renders as a bordered badge.
    @ViewBuilder
    private func tool(_ icon: String, active: Bool, label: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let label, !label.isEmpty {
                    Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(active ? .green : .white)
                        .padding(.horizontal, 5).frame(height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(active ? Color.green : Color.white, lineWidth: 1.5))
                } else {
                    Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(active ? .green : .white)
                }
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(StoryPressStyle())
    }

    // MARK: - Send
    private func send() async {
        posting = true
        let data = await flatten()
        posting = false
        pendingShare = StoryShareData(data: data)
    }

    @MainActor private func flatten() async -> Data {
        let base = edited
        let quality: CGFloat = hd ? 0.95 : 0.85
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // No drawing AND no caption → post the full-resolution edited image (HD keeps resolution).
        if drawing.bounds.isEmpty && cap.isEmpty {
            return base.jpegData(compressionQuality: quality) ?? Data()
        }
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        let composed = ZStack(alignment: .bottom) {
            Color.black
            // Bake the blurred fill behind, so an edited non-full-screen photo also reads like IG/WhatsApp.
            Image(uiImage: base).resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
                .blur(radius: 32).opacity(0.55)
            Image(uiImage: base).resizable().scaledToFit().frame(width: size.width, height: size.height)
            if !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale)).resizable()
            }
            if !cap.isEmpty {   // bake the caption (was silently dropped) — bottom band, like WhatsApp
                Text(cap)
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).shadow(radius: 4)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .frame(maxWidth: size.width)
                    .background(Color.black.opacity(0.32))
                    .padding(.bottom, size.height * 0.10)
            }
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: composed); r.scale = UIScreen.main.scale
        return r.uiImage?.jpegData(compressionQuality: quality) ?? (base.jpegData(compressionQuality: quality) ?? Data())
    }

    // MARK: - Image ops
    private static func apply(_ filterName: String?, to image: UIImage) -> UIImage {
        guard let filterName, let ci = CIImage(image: image),
              let filter = CIFilter(name: filterName) else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let out = filter.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private static func cropped(_ image: UIImage, aspect: CGFloat?) -> UIImage {
        guard let aspect, let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var cw = w, ch = h
        if w / h > aspect { cw = h * aspect } else { ch = w / aspect }
        let rect = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        guard let out = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }
}

// Springy press feedback for the story-editor controls.
struct StoryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// PencilKit drawing surface.
struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let isActive: Bool
    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.drawingPolicy = .anyInput
        v.backgroundColor = .clear
        v.isOpaque = false
        v.tool = PKInkingTool(.pen, color: .white, width: 6)
        v.delegate = context.coordinator
        return v
    }
    func updateUIView(_ v: PKCanvasView, context: Context) {
        if v.drawing != drawing { v.drawing = drawing }
        v.isUserInteractionEnabled = isActive
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: DrawingCanvas
        init(_ p: DrawingCanvas) { parent = p }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { parent.drawing = canvasView.drawing }
    }
}
