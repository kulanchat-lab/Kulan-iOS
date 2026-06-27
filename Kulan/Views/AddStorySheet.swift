import SwiftUI
import Photos

// Premium "Add Story" picker (screen 1): close + a Text quick-card + a 4-column grid whose first
// slot is a Camera tile and the rest are recent photos. Picking a photo (or capturing one) opens
// the premium StoryEditorView. Albums/Music/Layout are intentionally omitted (not faked).
struct AddStorySheet: View {
    var onPosted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PhotoGridStore()
    @State private var editorImage: EditorImage?
    @State private var showCamera = false
    @State private var showText = false

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                // Quick action card row (only the real one — Text).
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        quickCard("Aa", "Text", .green) { showText = true }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }

                LazyVGrid(columns: cols, spacing: 2) {
                    cameraTile
                    ForEach(store.assets, id: \.localIdentifier) { asset in
                        StoryThumb(asset: asset, store: store)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .onTapGesture {
                                Task { if let ui = await store.fullImage(asset) { editorImage = EditorImage(ui) } }
                            }
                    }
                }
                .padding(.horizontal, 2)
            }
            .navigationTitle("Add to Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
            .fullScreenCover(item: $editorImage) { item in
                StoryEditorView(source: item.image, onPosted: { onPosted(); dismiss() })
            }
            .fullScreenCover(isPresented: $showCamera) {
                StoryCameraView(onCapture: { d in if let ui = UIImage(data: d) { editorImage = EditorImage(ui) } },
                                onClose: { showCamera = false },
                                onTextMode: { showCamera = false; showText = true })
            }
            .fullScreenCover(isPresented: $showText) {
                StoryTextComposer(onShare: { d in Task { try? await StoriesService.shared.postStory(image: d); onPosted(); dismiss() } },
                                  onClose: { showText = false })
            }
            .task { store.load() }
        }
    }

    struct EditorImage: Identifiable { let id = UUID(); let image: UIImage; init(_ i: UIImage) { image = i } }

    private var cameraTile: some View {
        Button { showCamera = true } label: {
            ZStack {
                Color(.systemGray6)
                VStack(spacing: 6) {
                    Image(systemName: "camera.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 50, height: 50).background(.white, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    Text("Camera").font(.caption).foregroundStyle(.primary)
                }
            }
            .aspectRatio(1, contentMode: .fill).clipped()
        }
        .buttonStyle(.plain)
    }

    private func quickCard(_ glyph: String, _ label: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(glyph).font(.system(size: 26, weight: .bold)).foregroundStyle(color)
                Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            }
            .frame(width: 110, height: 90)
            .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))   // real iOS 26 glass
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
    }
}

// A grid thumbnail that loads its PHAsset image once (guarded against PhotoKit's double callback).
struct StoryThumb: View {
    let asset: PHAsset
    let store: PhotoGridStore
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemGray6)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .task {
                if image == nil {
                    let side = geo.size.width * UIScreen.main.scale
                    image = await store.thumbnail(asset, size: CGSize(width: side, height: side))
                }
            }
        }
    }
}

@MainActor
final class PhotoGridStore: ObservableObject {
    @Published var assets: [PHAsset] = []
    private let manager = PHCachingImageManager()

    func load() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else { return }
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let result = PHAsset.fetchAssets(with: opts)
            var arr: [PHAsset] = []
            result.enumerateObjects { a, _, _ in arr.append(a) }
            let limited = Array(arr.prefix(300))
            Task { @MainActor in self.assets = limited }
        }
    }

    func thumbnail(_ asset: PHAsset, size: CGSize) async -> UIImage? {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat   // fires once (no opportunistic double-callback)
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
    }

    func fullImage(_ asset: PHAsset) async -> UIImage? {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
    }
}
