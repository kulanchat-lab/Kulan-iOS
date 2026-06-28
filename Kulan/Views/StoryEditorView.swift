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
    @State private var croppedSource: UIImage?   // result of the interactive crop (nil = uncropped)
    @State private var showCrop = false
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
    private var edited: UIImage { editedCache ?? source }
    private func recomputeEdited() {
        // Filter applies on top of the (interactively) cropped source.
        editedCache = Self.apply(Self.filters[filterIndex].ci, to: croppedSource ?? source)
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
                    .opacity(editingID == o.id ? 0 : 1)   // hide the one being edited (it lives in the editor)
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
                                .frame(width: 48, height: 48).liquidGlass(Circle())   // real Apple glass
                        }
                        Spacer()
                        if isDrawing {
                            Button("Done") { isDrawing = false }.foregroundStyle(.white).fontWeight(.semibold)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, geo.safeAreaInsets.top + 6)
                    Spacer()
                }
                .opacity(draggingID == nil && editingID == nil ? 1 : 0)
                .ignoresSafeArea(.keyboard, edges: .bottom)

                // Bottom bar — ONLY this rises above the keyboard (caption docks above it, toolbar hides).
                VStack {
                    Spacer()
                    bottomBar
                        .padding(.bottom, captionFocused ? 8 : geo.safeAreaInsets.bottom + 8)
                }
                .opacity(draggingID == nil && editingID == nil ? 1 : 0)   // hide chrome while dragging text (trash owns the bottom)
            }
            .coordinateSpace(name: "canvas")
            .onAppear { canvasSize = geo.size; recomputeEdited() }
            .onChange(of: geo.size) { _, s in canvasSize = s }
            .onChange(of: filterIndex) { _, _ in recomputeEdited() }
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
        .fullScreenCover(isPresented: $showCrop) {
            // TOCropViewController (TimOliver) — proven crop engine. Always crop from the original.
            TOCropView(image: source,
                       onDone: { cropped in croppedSource = cropped; showCrop = false; recomputeEdited() },
                       onCancel: { showCrop = false })
                .ignoresSafeArea()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // Caption bar — dark pill, same as image 212.
            HStack(spacing: 10) {
                Image(systemName: "plus.square.on.square").foregroundStyle(.white)
                TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)))
                    .foregroundStyle(.white).focused($captionFocused)
            }
            .padding(.horizontal, 16).frame(height: 46)
            .background(Color(white: 0.13), in: Capsule())

            // Tool row hides while typing a caption (IG/WA: only the caption field stays, above the keyboard).
            if !captionFocused {
                HStack(spacing: 0) {
                    tool("textformat", active: false) { addTextOverlay() }   // Aa — add text on the photo
                    tool("crop", active: croppedSource != nil) { showCrop = true }
                    tool(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle", active: isDrawing) { isDrawing.toggle() }

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
            .frame(width: 44, height: 44)
            .liquidGlass(Circle())   // real Apple .glassEffect, not a custom background
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
        let quality: CGFloat = 0.9
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

// Real interactive crop, Telegram style: pan/zoom the image inside a fixed frame, surroundings DIMMED
// (you see what you're cropping out), rotation dial (-45°…45°) with auto-zoom so corners never gap,
// rotate-90, flip, aspect MENU, grid that fades in during a gesture, corner handles, Reset.
// Done renders exactly what's inside the frame. Body split into sub-views for the type-checker.
struct CropView: View {
    let source: UIImage
    var onDone: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @GestureState private var gScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var gOffset: CGSize = .zero
    @State private var angle: Double = 0          // fine rotation from the dial
    @GestureState private var dialDrag: CGFloat = 0
    @State private var quarter: Int = 0           // rotate-90 steps
    @State private var flipped = false
    @State private var aspectIdx = 0

    private var aspects: [(name: String, ratio: CGFloat)] {
        [("Original", source.size.height == 0 ? 1 : source.size.width / source.size.height),
         ("Square", 1), ("2:3", 2.0 / 3.0), ("3:5", 3.0 / 5.0), ("3:4", 3.0 / 4.0),
         ("4:5", 4.0 / 5.0), ("5:7", 5.0 / 7.0), ("9:16", 9.0 / 16.0)]
    }
    private var liveScale: CGFloat { max(1, scale * gScale) }
    private var liveOffset: CGSize { CGSize(width: offset.width + gOffset.width, height: offset.height + gOffset.height) }
    private var liveAngle: Double { min(45, max(-45, angle - Double(dialDrag) / 6)) }
    private var isEdited: Bool { angle != 0 || quarter != 0 || flipped || scale != 1 || offset != .zero }
    private var interacting: Bool { gScale != 1 || gOffset != .zero || dialDrag != 0 }

    // Min extra zoom so the (possibly rotated) image always covers the frame — no corner gaps.
    private func coverScale(_ angleDeg: Double, _ w: CGFloat, _ h: CGFloat) -> CGFloat {
        let r = angleDeg * .pi / 180
        let c = abs(CGFloat(cos(r))), s = abs(CGFloat(sin(r)))
        guard w > 0, h > 0 else { return 1 }
        return max((w * c + h * s) / w, (w * s + h * c) / h)
    }

    var body: some View {
        GeometryReader { geo in
            let ratio = aspects[aspectIdx].ratio
            let frameW: CGFloat = min(geo.size.width - 32, geo.size.height * 0.5 * ratio)
            let frameH: CGFloat = frameW / ratio
            ZStack {
                Color.black.ignoresSafeArea()
                cropArea(frameW: frameW, frameH: frameH)
                controls(geo: geo, frameW: frameW, frameH: frameH)
            }
        }
        .statusBarHidden()
    }

    private func cropArea(frameW: CGFloat, frameH: CGFloat) -> some View {
        ZStack {
            framedPhoto(frameW: frameW, frameH: frameH, live: true, clip: false)   // overflow shown
            Color.black.opacity(0.5).ignoresSafeArea()                              // dim the surroundings
                .reverseMask { RoundedRectangle(cornerRadius: 1).frame(width: frameW, height: frameH) }
                .allowsHitTesting(false)
            thirdsGrid.frame(width: frameW, height: frameH)
                .opacity(interacting ? 1 : 0).animation(.easeInOut(duration: 0.2), value: interacting)
                .allowsHitTesting(false)
            CropCorners().stroke(.white, lineWidth: 3).frame(width: frameW + 4, height: frameH + 4)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(SimultaneousGesture(zoomGesture, panGesture))
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture().updating($gScale) { v, s, _ in s = v }.onEnded { v in scale = max(1, scale * v) }
    }
    private var panGesture: some Gesture {
        DragGesture().updating($gOffset) { v, s, _ in s = v.translation }
            .onEnded { v in offset.width += v.translation.width; offset.height += v.translation.height }
    }

    private func controls(geo: GeometryProxy, frameW: CGFloat, frameH: CGFloat) -> some View {
        VStack {
            Spacer()
            Text("Reset")
                .font(.subheadline).foregroundStyle(.white.opacity(isEdited ? 1 : 0.4))
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { resetAll() } }
            rotationDial.frame(height: 40).padding(.vertical, 6)
            HStack {
                circleButton("xmark", bg: Color.white.opacity(0.18)) { onCancel() }
                Spacer()
                HStack(spacing: 26) {
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { quarter = (quarter + 1) % 4 } } label: {
                        Image(systemName: "rotate.left").font(.title3).foregroundStyle(.white)
                    }
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { flipped.toggle() } } label: {
                        Image(systemName: "arrow.left.and.right").font(.title3).foregroundStyle(flipped ? .green : .white)
                    }
                    Menu {
                        ForEach(aspects.indices, id: \.self) { i in
                            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { aspectIdx = i } } label: {
                                if aspectIdx == i { Label(aspects[i].name, systemImage: "checkmark") } else { Text(aspects[i].name) }
                            }
                        }
                    } label: {
                        Image(systemName: "aspectratio").font(.title3).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 20).frame(height: 48).background(Color.white.opacity(0.14), in: Capsule())
                Spacer()
                circleButton("checkmark", bg: Color.blue) { onDone(render(frameW: frameW, frameH: frameH)) }
            }
            .padding(.horizontal, 16).padding(.bottom, geo.safeAreaInsets.bottom + 14)
        }
    }

    private func circleButton(_ icon: String, bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(bg, in: Circle())
        }
    }

    // Photo: scaled-to-fill the frame, with rotation (+auto cover-zoom) + flip + zoom + pan.
    // clip=false for the on-screen view (overflow shows under the dim); clip=true for the output render.
    private func framedPhoto(frameW: CGFloat, frameH: CGFloat, live: Bool, clip: Bool) -> some View {
        let a: Double = (live ? liveAngle : angle) + Double(quarter) * 90
        let base: CGFloat = live ? liveScale : max(1, scale)
        let s: CGFloat = base * coverScale(a, frameW, frameH)
        let o: CGSize = live ? liveOffset : offset
        return Image(uiImage: source)
            .resizable().scaledToFill()
            .rotationEffect(.degrees(a))
            .scaleEffect(x: flipped ? -s : s, y: s)
            .offset(o)
            .frame(width: frameW, height: frameH)
            .allowsHitTesting(false)
            .modifier(ClipIf(clip: clip))
    }

    private var thirdsGrid: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }.stroke(.white.opacity(0.5), lineWidth: 0.5)
        }
    }

    private var rotationDial: some View {
        GeometryReader { g in
            ZStack {
                HStack(spacing: 7) {
                    ForEach(-45...45, id: \.self) { d in
                        Rectangle()
                            .fill(.white.opacity(d % 15 == 0 ? 0.9 : 0.35))
                            .frame(width: d % 15 == 0 ? 2 : 1, height: d % 15 == 0 ? 18 : 11)
                    }
                }
                .frame(maxHeight: .infinity)
                .offset(x: -CGFloat(liveAngle) * 9)
                Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(.green)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: g.size.width)
            .contentShape(Rectangle())
            .gesture(
                DragGesture().updating($dialDrag) { v, s, _ in s = v.translation.width }
                    .onEnded { v in angle = min(45, max(-45, angle - Double(v.translation.width) / 6)) }
            )
        }
    }

    private func resetAll() { scale = 1; offset = .zero; angle = 0; quarter = 0; flipped = false }

    @MainActor private func render(frameW: CGFloat, frameH: CGFloat) -> UIImage {
        let content = framedPhoto(frameW: frameW, frameH: frameH, live: false, clip: true)
        let r = ImageRenderer(content: content)
        r.scale = UIScreen.main.scale
        return r.uiImage ?? source
    }
}

// Conditionally clip a view to its frame (used so the crop's display shows overflow but the render doesn't).
private struct ClipIf: ViewModifier {
    let clip: Bool
    func body(content: Content) -> some View { clip ? AnyView(content.clipped()) : AnyView(content) }
}

extension View {
    // Punch a hole in `self` the shape of `mask` (used to dim everything except the crop frame).
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle().overlay(mask().blendMode(.destinationOut)).compositingGroup()
        }
    }
}

// L-shaped corner brackets for the crop frame.
struct CropCorners: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len: CGFloat = 22
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + len)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + len, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        return p
    }
}
