import SwiftUI
import PencilKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Premium full-screen story editor (WhatsApp/Instagram-style): the picked media fills the
// screen; a right-side tool rail does Aa (text) + pencil (draw); swipe up cycles filters;
// a caption capsule + audience pill + green send sit at the bottom. On send, the filtered
// image + drawing + text are flattened into one JPEG and posted via StoriesService.postStory.
struct StoryEditorView: View {
    let source: UIImage
    var onPosted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var textOverlays: [TextOverlay] = []
    @State private var editingText: TextOverlay?
    @State private var drawing = PKDrawing()
    @State private var isDrawing = false
    @State private var filterIndex = 0
    @State private var filteredCache: UIImage?       // recomputed only when the filter changes
    @State private var canvasSize: CGSize = .zero    // on-screen size, so the export matches WYSIWYG
    @State private var posting = false
    @State private var postError = false
    @State private var controlsIn = false   // controls fade/slide in when the editor opens
    @State private var pendingShare: StoryShareData?   // flattened image awaiting the audience sheet
    @State private var zoom: CGFloat = 1     // pinch-to-zoom the photo
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero    // pan while zoomed
    @State private var lastPan: CGSize = .zero

    private static let ciContext = CIContext()       // one shared context (cheap reuse)

    struct TextOverlay: Identifiable { let id = UUID(); var text: String; var pos: CGPoint }

    private static let filters: [(name: String, ci: String?)] = [
        ("Original", nil), ("Mono", "CIPhotoEffectMono"), ("Noir", "CIPhotoEffectNoir"),
        ("Fade", "CIPhotoEffectFade"), ("Chrome", "CIPhotoEffectChrome"), ("Instant", "CIPhotoEffectInstant"),
    ]

    private var displayImage: UIImage { filterIndex == 0 ? source : (filteredCache ?? source) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: displayImage)
                    .resizable().scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .scaleEffect(zoom)
                    .offset(pan)
                    .ignoresSafeArea()
                    // Pinch to zoom; one-finger pan when zoomed, otherwise swipe-up = filters.
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { v in zoom = min(5, max(1, lastZoom * v)) }
                                .onEnded { _ in
                                    lastZoom = zoom
                                    if zoom <= 1.01 {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { zoom = 1; pan = .zero }
                                        lastZoom = 1; lastPan = .zero
                                    }
                                },
                            DragGesture(minimumDistance: 12)
                                .onChanged { v in
                                    if zoom > 1 { pan = CGSize(width: lastPan.width + v.translation.width,
                                                              height: lastPan.height + v.translation.height) }
                                }
                                .onEnded { v in
                                    if zoom > 1 { lastPan = pan }
                                    else if v.translation.height < -40 { cycleFilter() }
                                }
                        )
                    )
                    .allowsHitTesting(!isDrawing)

                // Drawing canvas (only interactive while drawing).
                DrawingCanvas(drawing: $drawing, isActive: isDrawing)
                    .allowsHitTesting(isDrawing)
                    .ignoresSafeArea()

                // Draggable text overlays (above the swipe catcher so tap-to-edit/drag work).
                ForEach(textOverlays) { t in
                    Text(t.text)
                        .font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                        .shadow(radius: 4)
                        .position(t.pos)
                        .gesture(DragGesture().onChanged { v in move(t, to: v.location) })
                        .onTapGesture { editingText = t }
                }

                overlayControls(geo)
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, s in canvasSize = s }
        }
        .statusBarHidden()
        .alert("Couldn't share", isPresented: $postError) { Button("OK", role: .cancel) {} }
        .sheet(item: $editingText) { t in TextEntrySheet(text: t.text) { updated in commitText(t, updated) } }
        .sheet(item: $pendingShare) { s in ShareStorySheet(image: s.data, onPosted: { onPosted(); dismiss() }) }
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private func overlayControls(_ geo: GeometryProxy) -> some View {
        VStack {
            // Top row: close (left) + tool rail (right).
            HStack(alignment: .top) {
                roundIcon("xmark") { dismiss() }
                Spacer()
                VStack(spacing: 10) {
                    roundIcon(isDrawing ? "pencil.tip.crop.circle.fill" : "pencil.tip") { isDrawing.toggle() }
                    roundIcon("textformat") { addText() }
                }
            }
            .padding(.horizontal, 14).padding(.top, 8)

            Spacer()

            // Brief filter NAME flashes only while a filter is active (no "swipe up" prompt).
            if filterIndex != 0 {
                Text(Self.filters[filterIndex].name)
                    .font(.caption).foregroundStyle(.white).shadow(radius: 3)
                    .padding(.bottom, 10)
            }

            bottomBar
        }
        .opacity(controlsIn ? 1 : 0)
        .offset(y: controlsIn ? 0 : 12)
        .onAppear { withAnimation(.easeOut(duration: 0.35).delay(0.05)) { controlsIn = true } }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Caption capsule.
            HStack(spacing: 10) {
                Image(systemName: "plus.square.on.square").foregroundStyle(.white)
                TextField("", text: $caption, prompt: Text("Add a caption…").foregroundColor(Color(.systemGray3)))
                    .foregroundStyle(.white)
                Image(systemName: "at").foregroundStyle(.white)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .liquidGlass(Capsule())   // real glass caption bar

            // Audience pill + green send.
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed")
                    Text("Status").lineLimit(1)
                    Spacer()
                    Image(systemName: "plus")
                }
                .font(.subheadline).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 38)
                .liquidGlass(Capsule())   // real glass audience pill

                Button { Task { await send() } } label: {
                    Image(systemName: posting ? "ellipsis" : "paperplane.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 48, height: 48).background(Color(.systemGreen), in: Circle())
                        .shadow(color: Color(.systemGreen).opacity(0.5), radius: posting ? 2 : 8)
                }
                .buttonStyle(StoryPressStyle())
                .disabled(posting)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func roundIcon(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))   // icon morphs (e.g. pencil toggles)
                .frame(width: 40, height: 40)
                .liquidGlass(Circle(), interactive: true)     // real iOS 26 glass
        }
        .buttonStyle(StoryPressStyle())
    }

    // MARK: - Actions
    private func cycleFilter() {
        let next = (filterIndex + 1) % Self.filters.count
        filteredCache = next == 0 ? nil : Self.apply(Self.filters[next].ci, to: source)
        withAnimation(.easeInOut(duration: 0.2)) { filterIndex = next }
    }
    private func addText() { editingText = TextOverlay(text: "", pos: CGPoint(x: 200, y: 320)) }
    private func move(_ t: TextOverlay, to p: CGPoint) {
        if let i = textOverlays.firstIndex(where: { $0.id == t.id }) { textOverlays[i].pos = p }
    }
    private func commitText(_ t: TextOverlay, _ updated: String) {
        let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = textOverlays.firstIndex(where: { $0.id == t.id }) {
            if trimmed.isEmpty { textOverlays.remove(at: i) } else { textOverlays[i].text = trimmed }
        } else if !trimmed.isEmpty {
            textOverlays.append(TextOverlay(text: trimmed, pos: t.pos))
        }
    }

    // Green send → flatten, then open the audience sheet (Post Story uploads in the background).
    private func send() async {
        posting = true
        let data = await flatten()
        posting = false
        pendingShare = StoryShareData(data: data)
    }

    // Flatten at the ON-SCREEN size so text/drawing land exactly where the user placed them
    // (their positions are in screen points), then render at retina scale for sharpness.
    @MainActor private func flatten() async -> Data {
        let base = displayImage
        let size = canvasSize == .zero ? UIScreen.main.bounds.size : canvasSize
        let composed = ZStack {
            Image(uiImage: base).resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped()
                .scaleEffect(zoom).offset(pan)   // bake the pinch-zoom/pan into the export
                .frame(width: size.width, height: size.height).clipped()
            if !drawing.bounds.isEmpty {
                Image(uiImage: drawing.image(from: CGRect(origin: .zero, size: size), scale: UIScreen.main.scale)).resizable()
            }
            ForEach(textOverlays) { t in
                Text(t.text).font(.system(size: 30, weight: .bold)).foregroundStyle(.white).shadow(radius: 4)
                    .position(t.pos)
            }
        }
        .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: composed); r.scale = UIScreen.main.scale
        return r.uiImage?.jpegData(compressionQuality: 0.9) ?? (base.jpegData(compressionQuality: 0.9) ?? Data())
    }

    private static func apply(_ filterName: String?, to image: UIImage) -> UIImage {
        guard let filterName, let ci = CIImage(image: image),
              let filter = CIFilter(name: filterName) else { return image }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let out = filter.outputImage, let cg = ciContext.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
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

// Simple text-entry sheet for a story text overlay.
struct TextEntrySheet: View {
    @State var text: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            TextField("Type something…", text: $text, axis: .vertical)
                .font(.title2).padding().focused($focused)
                .navigationTitle("Text").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { onDone(text); dismiss() }.fontWeight(.semibold) }
                }
                .onAppear { focused = true }
        }
        .presentationDetents([.height(200)])
    }
}
