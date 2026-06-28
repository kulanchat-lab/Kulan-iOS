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

    // Text-on-photo overlays
    @State private var overlays: [TextOverlay] = []
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    @State private var draggingID: UUID?
    @State private var trashHot = false
    @State private var guideV = false
    @State private var guideH = false

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
                    .contentShape(Rectangle())
                    .onTapGesture { captionFocused = false; selectedID = nil }   // dismiss keyboard + deselect

                // Text overlays — above the photo, below the drawing canvas + controls.
                ForEach($overlays) { $o in
                    TextOverlayView(
                        overlay: $o,
                        isSelected: selectedID == o.id,
                        canvasSize: canvasSize,
                        interactive: !isDrawing && editingID == nil,
                        onTap: { selectedID = o.id; editingID = o.id },
                        onDragChange: { live in
                            draggingID = o.id
                            let hot = isOverTrash(live)
                            if hot != trashHot { trashHot = hot; if hot { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
                        },
                        onDragEnd: { live in
                            if isOverTrash(live) { overlays.removeAll { $0.id == o.id }; selectedID = nil }
                            draggingID = nil; trashHot = false; guideV = false; guideH = false
                        },
                        onSnap: { v, h in
                            if v && !guideV { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                            if h && !guideH { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                            guideV = v; guideH = h
                        }
                    )
                }

                if isDrawing {
                    DrawingCanvas(drawing: $drawing, isActive: true).ignoresSafeArea()
                }

                // Center alignment guides + trash zone (only while dragging an overlay).
                if draggingID != nil {
                    if guideV { Rectangle().fill(.yellow.opacity(0.9)).frame(width: 1).frame(maxHeight: .infinity).position(x: geo.size.width / 2, y: geo.size.height / 2) }
                    if guideH { Rectangle().fill(.yellow.opacity(0.9)).frame(height: 1).frame(maxWidth: .infinity).position(x: geo.size.width / 2, y: geo.size.height / 2) }
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(trashHot ? Color.red : .black.opacity(0.5), in: Circle())
                        .scaleEffect(trashHot ? 1.25 : 1)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: trashHot)
                        .position(trashCenter)
                }

                // Top controls — stay put when the keyboard opens (don't ride up with it).
                VStack {
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
                }
                .opacity(draggingID == nil ? 1 : 0)
                .ignoresSafeArea(.keyboard, edges: .bottom)

                // Bottom bar — ONLY this rises above the keyboard (caption docks above it, toolbar hides).
                VStack {
                    Spacer()
                    bottomBar
                        .padding(.bottom, captionFocused ? 8 : geo.safeAreaInsets.bottom + 8)
                }
                .opacity(draggingID == nil ? 1 : 0)   // hide chrome while dragging text (trash owns the bottom)
            }
            .coordinateSpace(name: "canvas")
            .onAppear { canvasSize = geo.size; recomputeEdited() }
            .onChange(of: geo.size) { _, s in canvasSize = s }
            .onChange(of: filterIndex) { _, _ in recomputeEdited() }
            .onChange(of: aspectIndex) { _, _ in recomputeEdited() }
            .overlay {
                if let id = editingID, let idx = overlays.firstIndex(where: { $0.id == id }) {
                    TextEditorOverlay(
                        draft: $overlays[idx],
                        onCancel: { trimEmpty(id); editingID = nil },
                        onDone: { trimEmpty(id); editingID = nil }
                    )
                }
            }
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

            // Tool row hides while typing a caption (IG/WA: only the caption field stays, above the keyboard).
            if !captionFocused {
                HStack(spacing: 0) {
                    tool("textformat", active: false) { addTextOverlay() }   // Aa — add text on the photo
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

    // MARK: - Text overlays
    private var trashCenter: CGPoint { CGPoint(x: canvasSize.width / 2, y: canvasSize.height - 110) }
    private func isOverTrash(_ p: CGPoint) -> Bool { hypot(p.x - trashCenter.x, p.y - trashCenter.y) < 64 }
    private func addTextOverlay() {
        captionFocused = false
        let o = TextOverlay(center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        overlays.append(o)
        selectedID = o.id
        editingID = o.id   // open the editor immediately
    }
    private func trimEmpty(_ id: UUID) {
        if let idx = overlays.firstIndex(where: { $0.id == id }),
           overlays[idx].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            overlays.remove(at: idx); selectedID = nil
        }
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
        // No drawing AND no caption AND no text overlays → post the full-resolution edited image.
        if drawing.bounds.isEmpty && cap.isEmpty && overlays.isEmpty {
            return base.jpegData(compressionQuality: quality) ?? Data()
        }
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        let composed = ZStack(alignment: .bottom) {
            Color.black
            // Bake the blurred fill behind, so an edited non-full-screen photo also reads like IG/WhatsApp.
            Image(uiImage: base).resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
                .blur(radius: 32).opacity(0.55)
            // Fill the frame (crop, never stretch) so a captioned/edited photo posts full — the
            // preview card then shows it filled like WhatsApp, not small with bars. (Overlays use
            // canvas coords so their positions are unaffected by fill vs fit.)
            Image(uiImage: base).resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
            if !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale)).resizable()
            }
            // Bake the text overlays — same builder + transforms as on-screen → WYSIWYG.
            ForEach(overlays) { o in
                storyStyledText(o, maxWidth: size.width * 0.9)
                    .scaleEffect(o.scale)
                    .rotationEffect(o.rotation)
                    .position(o.center)
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

// MARK: - Text-on-photo overlay (Telegram/Instagram style)

struct TextOverlay: Identifiable, Equatable {
    let id = UUID()
    var text: String = ""
    var center: CGPoint                 // in canvasSize coordinates → WYSIWYG with flatten
    var scale: CGFloat = 1
    var rotation: Angle = .zero
    var color: Color = .white
    var alignment: TextAlignment = .center
    var font: FontStyle = .rounded
    var background: BgStyle = .plain
    var baseSize: CGFloat = 34

    enum FontStyle: String, CaseIterable, Equatable {
        case rounded, classic, serif, mono
        var design: Font.Design {
            switch self {
            case .rounded: return .rounded
            case .classic: return .default
            case .serif:   return .serif
            case .mono:    return .monospaced
            }
        }
    }
    enum BgStyle: String, CaseIterable, Equatable { case plain, semi, solid }
}

// Shared styled text — used BOTH on-screen and in flatten() so export == screen.
@ViewBuilder
func storyStyledText(_ o: TextOverlay, maxWidth: CGFloat) -> some View {
    Text(o.text.isEmpty ? " " : o.text)
        .font(.system(size: o.baseSize, weight: .semibold, design: o.font.design))
        .multilineTextAlignment(o.alignment)
        .foregroundStyle(o.background == .solid ? Color.black : o.color)
        .padding(.horizontal, o.background == .plain ? 6 : 14)
        .padding(.vertical, o.background == .plain ? 2 : 8)
        .background {
            switch o.background {
            case .plain: Color.clear
            case .semi:  RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38))
            case .solid: RoundedRectangle(cornerRadius: 10).fill(o.color)
            }
        }
        .shadow(color: .black.opacity(o.background == .plain ? 0.55 : 0), radius: 3, y: 1)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: maxWidth)
}

// One draggable / pinchable / rotatable / tappable text overlay.
struct TextOverlayView: View {
    @Binding var overlay: TextOverlay
    let isSelected: Bool
    let canvasSize: CGSize
    let interactive: Bool
    var onTap: () -> Void
    var onDragChange: (CGPoint) -> Void
    var onDragEnd: (CGPoint) -> Void
    var onSnap: (Bool, Bool) -> Void

    @GestureState private var dragT: CGSize = .zero
    @GestureState private var gScale: CGFloat = 1
    @GestureState private var gRot: Angle = .zero

    private func snappedPure(_ p: CGPoint) -> CGPoint {
        let cx = canvasSize.width / 2, cy = canvasSize.height / 2, t: CGFloat = 12
        var out = p
        if abs(p.x - cx) < t { out.x = cx }
        if abs(p.y - cy) < t { out.y = cy }
        return out
    }
    private var liveCenter: CGPoint {
        snappedPure(CGPoint(x: overlay.center.x + dragT.width, y: overlay.center.y + dragT.height))
    }
    private var liveScale: CGFloat { max(0.3, overlay.scale * gScale) }
    private var liveRot: Angle { overlay.rotation + gRot }

    var body: some View {
        storyStyledText(overlay, maxWidth: canvasSize.width * 0.9)
            .scaleEffect(liveScale)
            .rotationEffect(liveRot)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundStyle(.white.opacity(0.9)).padding(-6)
                }
            }
            .position(liveCenter)
            .allowsHitTesting(interactive)
            .highPriorityGesture(TapGesture().onEnded { onTap() })
            .gesture(transform, including: interactive ? .all : .none)
    }

    private var transform: some Gesture {
        let drag = DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .updating($dragT) { v, s, _ in s = v.translation }
            .onChanged { v in
                let raw = CGPoint(x: overlay.center.x + v.translation.width, y: overlay.center.y + v.translation.height)
                let cx = canvasSize.width / 2, cy = canvasSize.height / 2, t: CGFloat = 12
                onSnap(abs(raw.x - cx) < t, abs(raw.y - cy) < t)
                onDragChange(snappedPure(raw))
            }
            .onEnded { v in
                let nc = snappedPure(CGPoint(x: overlay.center.x + v.translation.width, y: overlay.center.y + v.translation.height))
                overlay.center = nc
                onDragEnd(nc)
            }
        let mag = MagnifyGesture()
            .updating($gScale) { v, s, _ in s = v.magnification }
            .onEnded { v in overlay.scale = max(0.3, overlay.scale * v.magnification) }
        let rot = RotateGesture()
            .updating($gRot) { v, s, _ in s = v.rotation }
            .onEnded { v in overlay.rotation += v.rotation }
        return SimultaneousGesture(drag, SimultaneousGesture(mag, rot))
    }
}

// Full-screen text editor (Telegram image 220): focused field + font/color/align/bg controls.
struct TextEditorOverlay: View {
    @Binding var draft: TextOverlay
    var onCancel: () -> Void
    var onDone: () -> Void
    @FocusState private var focused: Bool

    private let palette: [Color] = [.white, .black, .red, .orange, .yellow, .green, .blue, .purple, .pink]
    private func nextAlign(_ a: TextAlignment) -> TextAlignment { a == .leading ? .center : a == .center ? .trailing : .leading }
    private func alignIcon(_ a: TextAlignment) -> String { a == .leading ? "text.alignleft" : a == .center ? "text.aligncenter" : "text.alignright" }
    private func nextBg(_ b: TextOverlay.BgStyle) -> TextOverlay.BgStyle { b == .plain ? .semi : b == .semi ? .solid : .plain }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { onDone() }
            VStack {
                HStack {
                    Button("Cancel") { onCancel() }.foregroundStyle(.white)
                    Spacer()
                    Button { draft.alignment = nextAlign(draft.alignment) } label: { Image(systemName: alignIcon(draft.alignment)).foregroundStyle(.white) }
                    Button { draft.background = nextBg(draft.background) } label: { Image(systemName: "a.square").foregroundStyle(.white).opacity(draft.background == .plain ? 0.5 : 1) }
                    Spacer()
                    Button("Done") { onDone() }.foregroundStyle(.white).fontWeight(.semibold)
                }
                .padding()
                Spacer()
                TextField("", text: $draft.text, prompt: Text("Type…").foregroundColor(.white.opacity(0.5)), axis: .vertical)
                    .focused($focused)
                    .multilineTextAlignment(draft.alignment)
                    .font(.system(size: draft.baseSize, weight: .semibold, design: draft.font.design))
                    .foregroundStyle(draft.background == .solid ? Color.black : draft.color)
                    .tint(.white)
                    .padding(draft.background == .plain ? 6 : 14)
                    .background {
                        switch draft.background {
                        case .plain: Color.clear
                        case .semi:  RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.38))
                        case .solid: RoundedRectangle(cornerRadius: 10).fill(draft.color)
                        }
                    }
                    .frame(maxWidth: 320)
                Spacer()
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        ForEach(TextOverlay.FontStyle.allCases, id: \.self) { fs in
                            Text("Aa").font(.system(size: 16, weight: .semibold, design: fs.design))
                                .foregroundStyle(draft.font == fs ? Color.black : .white)
                                .frame(width: 42, height: 30)
                                .background(draft.font == fs ? Color.white : Color.white.opacity(0.15), in: Capsule())
                                .onTapGesture { draft.font = fs }
                        }
                    }
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { c in
                            Circle().fill(c).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.white, lineWidth: draft.color == c ? 3 : 1))
                                .onTapGesture { draft.color = c }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .onAppear { focused = true }
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
