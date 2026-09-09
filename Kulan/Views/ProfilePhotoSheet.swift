import SwiftUI
import Photos
import UIKit

// THE EDIT PHOTO PAGE — his redesign, 2026-09-02: "when I click edit photo I see a small sheet;
// redesign it, show a full page like image 2, exactly like that".
//
// His reference: ✕ / "Edit Photo" / ✓ across the top, the picture large in the middle wearing a
// remove badge, one "Add a Photo" button under it, then Recents and Emoji. The button read
// "Choose a Photo" until 2026-09-05, when he renamed it; nothing about what it does changed.
//
// ⛔ THE SHEET DECIDES, IT DOES NOT DO. Unchanged from the small version and the one rule on this
// screen that must not be relaxed: every action is recorded here and run by the presenter in
// `onDismiss`. Presenting a camera, a photo picker or an alert from inside a sheet that is still
// dismissing is the "nothing happens" bug this app has been bitten by twice, and the note at the top
// of BottomActionSheet.swift says so in as many words.
//
// ⛔ THE PAGE TAKES ITS COLOUR FROM THE PHOTOGRAPH — his instruction, same message: "this page uses
// the profile colour… don't forget, the background must use the photo colour; when the user doesn't
// have a photo use the normal colour". `ProfilePalette` is the same extractor `ContactInfoView` and
// the Glow profile use, so all three agree about what colour a person is.

enum ProfilePhotoAction {
    case camera     // Apple's camera, to take a new one
    case library    // Apple's photo picker, to choose one
    case remove     // no picture, back to the letter
    /// A photograph the page resolved itself, from Recents. It goes to the SAME cropper a chosen one
    /// does — one framing path, so only one of them can be wrong.
    case image(UIImage)
    /// An emoji drawn onto a coloured disc. Already square and already centred, so it skips the
    /// cropper: there is nothing to frame and asking would be a step that can only make it worse.
    case emoji(UIImage)
}

struct ProfilePhotoSheet: View {
    let name: String
    /// The saved picture. Nil while a removal is pending, so the page shows what you are about to
    /// have rather than what you just asked to get rid of.
    let photoUrl: String?
    /// A picked-but-not-yet-saved photo wins over the saved one, for the same reason.
    let pendingImage: UIImage?
    let canRemove: Bool
    @Binding var action: ProfilePhotoAction?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var palette: ProfilePalette?
    @State private var recents: [UIImage] = []

    private let circle: CGFloat = 190

    /// The page's ground. His rule, stated twice in one message: the photo's colour when there is a
    /// photo, the ordinary background when there is not.
    private var pageColor: Color {
        palette.map { Color($0.page) } ?? Color(.systemBackground)
    }

    /// White on a colour, label on the ordinary background — because `pageColor` is a photograph's
    /// tone in one case and the system's surface in the other, and one foreground cannot serve both.
    private var ink: Color { palette == nil ? Color(.label) : .white }

    var body: some View {
        ZStack {
            pageColor.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    photo
                        .overlay(alignment: .topTrailing) { removeBadge }
                        .padding(.top, 26)
                    choosePhotoButton
                        .padding(.top, 24)
                    recentsSection
                    emojiSection
                    Color.clear.frame(height: 28)
                }
            }
        }
        // A photograph's tone is a dark ground; the ordinary background keeps the phone's own scheme.
        .environment(\.colorScheme, palette == nil ? scheme : .dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task { await load() }
    }

    // MARK: - Chrome

    private var header: some View {
        ZStack {
            Text("Edit Photo").font(.headline).foregroundStyle(ink)
            HStack {
                glyphButton("xmark") { dismiss() }
                Spacer(minLength: 0)
                // ⚠️ ✓ IS "DONE", NOT "APPLY". Every pick on this page already closes it and hands
                // the presenter the action, so by the time this is reachable there is nothing left
                // to commit — and the real commit is Save on the screen behind, which is the rule
                // his own "don't update the profile image without save" set.
                glyphButton("checkmark") { dismiss() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func glyphButton(_ system: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var photo: some View {
        Group {
            if let pendingImage {
                Image(uiImage: pendingImage).resizable().scaledToFill()
                    .frame(width: circle, height: circle)
                    .clipShape(Circle())
            } else {
                AvatarView(name: name, photoUrl: photoUrl, size: circle)
            }
        }
        .frame(width: circle, height: circle)
    }

    /// ⛔ A MINUS, NOT AN ✕ — his reference draws a "−" on the picture. The two read differently and
    /// the difference is right: ✕ next to a ✕ in the corner of the same screen is two closes, while
    /// a minus is plainly "take this away".
    @ViewBuilder private var removeBadge: some View {
        if canRemove {
            Button { choose(.remove) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 40, height: 40)
                    .liquidGlass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: 8)
            .accessibilityLabel("Remove photo")
        }
    }

    /// ⛔ A MENU, NOT TWO BUTTONS — his instruction, when this button was still called "Choose a
    /// Photo": "when the user clicks Choose a Photo show a context menu: camera, photo library".
    /// The old page carried both as separate capsules; one button and a menu is his reference and it
    /// is also the honest shape, since the two are the same decision made two ways.
    private var choosePhotoButton: some View {
        Menu {
            Button { choose(.camera) } label: { Label("Camera", systemImage: "camera") }
            Button { choose(.library) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
        } label: {
            Text("Add a Photo")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
                // ⛔ 44, HIS NUMBER — 2026-09-02, with the button ringed. It was 52, which is a
                // primary-action height, and this is not the page's primary action: the picture
                // above it is, and Recents and Emoji under it are two more ways to change it. 44 is
                // also Apple's touch floor, so it gives nothing up.
                .frame(height: 44)
                .padding(.horizontal, 30)
                .liquidGlass(Capsule(), interactive: true)
                .contentShape(Capsule())
        }
    }

    // MARK: - Recents

    /// ⚠️ SILENT WHEN THERE IS NOTHING TO SHOW. No photo access, or an empty library, draws no
    /// heading at all — a "Recents" label over a blank strip is a section that looks broken rather
    /// than one that is empty.
    @ViewBuilder private var recentsSection: some View {
        if !recents.isEmpty {
            sectionTitle("Recents")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(recents.enumerated()), id: \.offset) { _, img in
                        Button { choose(.image(img)) } label: {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 76, height: 76)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Emoji

    /// ⛔ HIS OWN EMOJI, NOT ONES THE APP PICKED — his instruction, 2026-09-05, with the old block
    /// ringed: no generated suggestions. What stood here was a stated grid of twelve faces read off
    /// a reference screenshot, which is the app choosing his content for him. This row shows the
    /// emoji HE has reached for, newest first, capped at ten, and nothing else.
    ///
    /// ⚠️ SILENT WHEN THERE IS NOTHING TO SHOW, the same rule Recents follows above: a heading over
    /// a blank strip reads as broken rather than empty. Somebody who has never used an emoji in the
    /// app therefore sees no emoji section at all, and the page is the picture, the button and
    /// Recents. That is the honest empty state, not a gap to be filled with a default set.
    @ViewBuilder private var emojiSection: some View {
        if !recentEmoji.isEmpty {
            sectionTitle("Emoji")
            // ⛔ FOUR ACROSS, WRAPPING, AT THE CONCEPT'S SIZE — his report, 2026-09-09: "make it
            // recent emojis up to like 10, exactly same size like this concept". His picture is a
            // grid four wide with circles noticeably larger than ours, not a strip that scrolls
            // sideways. Ten recents fill three rows there and one long row here, which is what made
            // ours look like a different screen.
            //
            // ⚠️ THE SIZE IS NOT TYPED, IT IS WHAT FOUR COLUMNS LEAVE. On his phone that lands near
            // 87, which is the circle he measured; typing 87 would be right on one screen width and
            // wrong on every other.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                      spacing: 14) {
                ForEach(recentEmoji, id: \.self) { e in
                    Button { choose(.emoji(Self.render(e, on: Self.disc(for: e)))) } label: {
                        ZStack {
                            Circle().fill(Color(Self.disc(for: e)))
                            Text(e).font(.system(size: 38))
                        }
                        .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    /// The emoji this person has actually used, newest first.
    ///
    /// ⚠️ ONE STORE, SHARED WITH REACTIONS. `ReactionRecents` is the only record the app keeps of
    /// which emoji somebody reaches for — it is written every time a reaction is set, in ThreadView's
    /// `react` — and it already trims itself to ten. Reading it here rather than starting a second
    /// list means this page and the reaction bar can never disagree about what "recent" means. If
    /// the app ever gains a second place emoji are chosen, it should write to this same store.
    private var recentEmoji: [String] { Array(ReactionRecents.get().prefix(10)) }

    /// The disc an emoji is drawn on.
    ///
    /// ⚠️ THE APP'S EXISTING COLOUR RULE, NOT A NEW ONE. The old grid carried a stated colour per
    /// face, which was only possible because those twelve faces were known in advance; a recents
    /// list is not. `AvatarPalette` already answers "what colour is this string" for every letter
    /// avatar in the app, so an emoji is coloured the same way a name is: stable for a given emoji,
    /// and taken from eight deep tones, none of them pale enough to swallow the glyph on top.
    private static func disc(for emoji: String) -> UIColor {
        UIColor(AvatarPalette.gradient(for: emoji)[0])
    }

    private func sectionTitle(_ t: String) -> some View {
        HStack {
            Text(t).font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
    }

    /// Draw an emoji onto a filled disc at avatar resolution.
    ///
    /// ⚠️ 512, NOT THE 76 IT IS SHOWN AT. This image becomes the profile picture, so it is rendered
    /// once at the size every other avatar in the app is stored at rather than at the size of the
    /// button that was tapped — a 76pt disc blown up to a poster header is exactly the kind of soft
    /// picture this screen exists to avoid.
    private static func render(_ emoji: String, on colour: UIColor, size: CGFloat = 512) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: rect.size).image { ctx in
            colour.setFill()
            ctx.cgContext.fillEllipse(in: rect)
            let font = UIFont.systemFont(ofSize: size * 0.52)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let s = NSString(string: emoji)
            let bounds = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: (size - bounds.width) / 2,
                               y: (size - bounds.height) / 2),
                   withAttributes: attrs)
        }
    }

    // MARK: - Loading

    private func load() async {
        if let url = photoUrl, !url.isEmpty {
            if let hit = ProfilePalette.cached(for: url) {
                palette = hit
            } else {
                palette = await ProfilePalette.resolve(url: url)
            }
        }
        recents = await Self.recentImages()
    }

    /// The newest few pictures, as decoded thumbnails.
    ///
    /// ⚠️ READ-ONLY AND SILENT. It never ASKS for photo access — the picker does that, at the moment
    /// somebody actually reaches for the library. Prompting on the way into this page would put a
    /// system alert in front of a screen most people open to press one emoji.
    private static func recentImages(_ count: Int = 8) async -> [UIImage] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let f = PHFetchOptions()
        f.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        f.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        f.fetchLimit = count
        let result = PHAsset.fetchAssets(with: f)
        guard result.count > 0 else { return [] }

        let manager = PHImageManager.default()
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        opts.isSynchronous = false

        var out: [UIImage] = []
        for i in 0..<result.count {
            let asset = result.object(at: i)
            let img: UIImage? = await withCheckedContinuation { cont in
                var resumed = false
                manager.requestImage(for: asset,
                                     targetSize: CGSize(width: 300, height: 300),
                                     contentMode: .aspectFill,
                                     options: opts) { image, info in
                    // ⚠️ `.opportunistic` CALLS BACK TWICE and a continuation may only resume once.
                    // `.highQualityFormat` above is one callback, and this guard is the belt for the
                    // day somebody changes that line without reading this one.
                    guard !resumed else { return }
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    guard !degraded || image == nil else { return }
                    resumed = true
                    cont.resume(returning: image)
                }
            }
            if let img { out.append(img) }
        }
        return out
    }

    private func choose(_ a: ProfilePhotoAction) {
        action = a
        dismiss()
    }
}
