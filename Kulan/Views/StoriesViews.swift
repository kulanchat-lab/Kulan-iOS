import SwiftUI
import PhotosUI
import UIKit

// Cached story image: loads once, caches by URL, so swiping back/forward and replays
// never re-download (kills the flashing/lag). Falls back gracefully if a URL is broken.
private final class StoryImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>(); c.countLimit = 60; return c
    }()
}

struct StoryImage: View {
    let url: String
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                ZStack { Color.black; Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.5)) }
            } else {
                SkeletonFill()   // shimmer placeholder instead of a spinner
            }
        }
        .task(id: url) { await load() }
    }
    private func load() async {
        failed = false
        if let cached = StoryImageCache.shared.object(forKey: url as NSString) { image = cached; return }
        guard let u = URL(string: url) else { failed = true; return }
        guard let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data) else {
            failed = true; return
        }
        StoryImageCache.shared.setObject(img, forKey: url as NSString)
        image = img
    }
}

// Local per-author story prefs: hide a person's stories from the row, toggle "notify".
// Persisted in UserDefaults (space-joined uid sets), like the reaction recents.
enum StoryPrefs {
    private static func set(_ key: String) -> Set<String> {
        Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: " ").map(String.init))
    }
    private static func save(_ key: String, _ s: Set<String>) {
        UserDefaults.standard.set(s.joined(separator: " "), forKey: key)
    }
    static func isHidden(_ uid: String) -> Bool { set("hiddenStories").contains(uid) }
    static func toggleHidden(_ uid: String) {
        var s = set("hiddenStories"); if s.contains(uid) { s.remove(uid) } else { s.insert(uid) }; save("hiddenStories", s)
    }
    static func isNotifying(_ uid: String) -> Bool { set("notifyStories").contains(uid) }
    static func toggleNotify(_ uid: String) {
        var s = set("notifyStories"); if s.contains(uid) { s.remove(uid) } else { s.insert(uid) }; save("notifyStories", s)
    }
}

// Horizontal Stories row for the top of the Chats screen: "My Status" cell (tap to add
// or view your own) + friends' rings (unseen = accent ring, seen = grey). Loads on appear.
struct StoriesRow: View {
    @State private var repo = StoriesRepository.shared
    var meName: String
    var mePhoto: String?
    var onCompose: () -> Void
    var onOpen: (StoryGroup) -> Void
    var onMessage: (StoryGroup) -> Void = { _ in }
    var onProfile: (StoryGroup) -> Void = { _ in }
    var onOpenAnon: (StoryGroup) -> Void = { _ in }
    @State private var prefsTick = 0   // re-render after hide/notify toggles

    private let storySpacing: CGFloat = 10
    private let storyHPad: CGFloat = 12
    // Size cards so EXACTLY 4 fit the screen width with even gaps — no half card at the edge.
    private var cardW: CGFloat {
        (UIScreen.main.bounds.width - storyHPad * 2 - storySpacing * 3) / 4
    }
    private var cardH: CGFloat { cardW * 1.46 }   // "people"-card proportions

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: storySpacing) {
                myCard
                ForEach(repo.others.filter { !StoryPrefs.isHidden($0.authorUid) }) { g in
                    card(cover: g.stories.last?.mediaUrl,
                         name: g.name.isEmpty ? "User" : g.name,
                         avatar: g.photoUrl, unseen: g.hasUnseen) { onOpen(g) }
                        .contextMenu {
                            Button { onMessage(g) } label: { Label("Send Message", systemImage: "message") }
                            Button { onProfile(g) } label: { Label("Open Profile", systemImage: "person") }
                            Button { StoryPrefs.toggleNotify(g.authorUid); prefsTick += 1 } label: {
                                Label(StoryPrefs.isNotifying(g.authorUid) ? "Stop Notifying" : "Notify About Stories",
                                      systemImage: StoryPrefs.isNotifying(g.authorUid) ? "bell.slash" : "bell")
                            }
                            Button { onOpenAnon(g) } label: { Label("View Anonymously", systemImage: "eye.slash") }
                            Button(role: .destructive) { StoryPrefs.toggleHidden(g.authorUid); prefsTick += 1 } label: {
                                Label("Hide Stories", systemImage: "archivebox")
                            }
                        } preview: {
                            storyMenuPreview(g)   // lift ONLY the held story card, not the whole row
                        }
                }
            }
            .padding(.horizontal, storyHPad)
            .padding(.vertical, 10)
        }
        .task { await repo.load() }
    }

    // My Status: my latest story photo (or my avatar) as the cover, a + badge to add.
    private var myCard: some View {
        card(cover: repo.mine?.stories.last?.mediaUrl ?? mePhoto,
             name: "My Story", avatar: mePhoto,
             unseen: repo.mine?.hasUnseen ?? false, onBadge: onCompose) {
            if let m = repo.mine { onOpen(m) } else { onCompose() }
        }
    }

    // A cover card: rounded photo, accent border when unseen, small corner avatar (or a +
    // badge for My Story), name underneath.
    private func card(cover: String?, name: String, avatar: String?, unseen: Bool,
                      onBadge: (() -> Void)? = nil, tap: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                coverImage(cover, name: name, avatar: avatar)
                    .frame(width: cardW, height: cardH)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    // No border/frame on the card itself — the viewed/unviewed ring lives
                    // only on the avatar badge below.
                if let onBadge {
                    Button(action: onBadge) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 26)).symbolRenderingMode(.palette)
                            // plus glyph = page bg, circle = primary -> always contrasts in
                            // both modes (accent is white in dark, so the old version was all white).
                            .foregroundStyle(Color(.systemBackground), .primary)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain).padding(8)
                } else {
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        // Status ring ONLY here: accent when unseen, gone once viewed.
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: unseen ? 2.5 : 0))
                        .animation(.easeInOut(duration: 0.3), value: unseen)   // fade the ring on view
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                }
            }
            Text(name).font(.system(size: 12)).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }

    @ViewBuilder private func coverImage(_ cover: String?, name: String, avatar: String?) -> some View {
        if let cover, !cover.isEmpty {
            StoryImage(url: cover)   // cached -> the row stops re-downloading covers on every scroll
        } else {
            ZStack {
                Color.secondary.opacity(0.2)
                AvatarView(name: name, photoUrl: avatar, size: cardW * 0.62)
            }
        }
    }

    // Single-card preview for the long-press menu — only the held story lifts (not the row).
    @ViewBuilder private func storyMenuPreview(_ g: StoryGroup) -> some View {
        Group {
            if let cover = g.stories.last?.mediaUrl, !cover.isEmpty {
                StoryImage(url: cover)
            } else {
                ZStack { Color.secondary.opacity(0.2); AvatarView(name: g.name, photoUrl: g.photoUrl, size: 110) }
            }
        }
        .frame(width: 210, height: 300)
    }

    func reload() { Task { await repo.load() } }
}

// Full-screen story viewer: top progress bars, tap-right = next / tap-left = back,
// auto-advance, swipe-down to close. Marks each shown story viewed.
struct StoryViewer: View {
    let group: StoryGroup
    var anonymous: Bool = false   // "View Anonymously" -> don't send a view receipt
    var onClose: () -> Void

    @State private var index = 0
    @State private var progress = 0.0
    @State private var closing = false
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var paused = false                 // hold-to-pause
    @State private var viewed = Set<String>()         // de-dupe view receipts
    @State private var showSent = false               // toast visibility
    @State private var toastText = "Sent"             // toast text (Sent / Saved / Reported)
    @State private var keyboardHeight: CGFloat = 0     // lift the reply bar above the keyboard
    private let quickEmojis = ["❤️", "😂", "😮", "😢", "👏", "🔥"]
    private let ticker = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    private let perStory = 5.0   // seconds per photo

    private var story: Story? { group.stories.indices.contains(index) ? group.stories[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let s = story {
                StoryImage(url: s.mediaUrl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
            }

            // Tap zones: tap left = back, tap right = next; press-and-hold = pause.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity)
                    .onTapGesture { back() }
                    .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 40, perform: {}, onPressingChanged: { paused = $0 })
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity)
                    .onTapGesture { next() }
                    .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 40, perform: {}, onPressingChanged: { paused = $0 })
            }

            VStack {
                HStack(spacing: 4) {
                    ForEach(group.stories.indices, id: \.self) { i in
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.3))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white)
                                        .frame(width: geo.size.width * fill(i))
                                        .animation(.linear(duration: 0.05), value: progress)   // smooth fill, no stepping
                                }
                        }
                        .frame(height: 2.5)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 8)

                HStack(spacing: 10) {
                    AvatarView(name: group.name, photoUrl: group.photoUrl, size: 32)
                    Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    if let s = story {
                        Text(timeAgo(s.createdAt)).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Menu {
                        Button { saveToGallery() } label: { Label("Save to Gallery", systemImage: "square.and.arrow.down") }
                        if group.isMine {
                            Button(role: .destructive) { deleteCurrentStory() } label: { Label("Delete", systemImage: "trash") }
                        } else {
                            Button { StoryPrefs.toggleNotify(group.authorUid) } label: {
                                Label(StoryPrefs.isNotifying(group.authorUid) ? "Stop Notifying" : "Notify About Stories",
                                      systemImage: StoryPrefs.isNotifying(group.authorUid) ? "bell.slash" : "bell")
                            }
                            Button(role: .destructive) { StoryPrefs.toggleHidden(group.authorUid); onClose() } label: {
                                Label("Hide Stories", systemImage: "archivebox")
                            }
                            Button(role: .destructive) { reportStory() } label: { Label("Report", systemImage: "exclamationmark.bubble") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                    }
                    .padding(.trailing, 2)
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8)
                Spacer()
                // Reply bar (Signal stories logic) — only on someone else's story that allows replies.
                if let s = story, !group.isMine, s.allowsReplies {
                    VStack(spacing: 0) {
                        reactionRow(s)
                        replyBar(s)
                    }
                    .padding(.bottom, keyboardHeight)   // rise above the keyboard when typing
                    .animation(.easeOut(duration: 0.25), value: keyboardHeight)
                }
            }

            if showSent {
                Text(toastText).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.black.opacity(0.65), in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSent)
        .onReceive(ticker) { _ in tick() }
        .task(id: index) {
            guard !anonymous, let s = story, !viewed.contains(s.id) else { return }
            viewed.insert(s.id); await StoriesService.shared.markViewed(s)
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in if v.translation.height > 80 { onClose() } })
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            if let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = max(0, UIScreen.main.bounds.height - f.origin.y)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardHeight = 0 }
    }

    private func fill(_ i: Int) -> Double { i < index ? 1 : (i == index ? progress : 0) }

    private func tick() {
        // Pause on: dismissing, typing a reply, finger held, or app not active.
        guard !closing, !replyFocused, !paused, scenePhase == .active, story != nil else { return }
        progress = min(progress + 0.02 / perStory, 1)
        if progress >= 1 { next() }
    }

    private func next() {
        if index < group.stories.count - 1 { index += 1; progress = 0 }
        else { closing = true; onClose() }   // last story: close once
    }

    private func back() {
        if index > 0 { index -= 1; progress = 0 } else { progress = 0 }
    }

    // Quick-emoji reaction row (Instagram/Signal) — taps send straight to the author's chat.
    @ViewBuilder private func reactionRow(_ s: Story) -> some View {
        HStack(spacing: 16) {
            ForEach(quickEmojis, id: \.self) { e in
                Button { sendToAuthor(s, e) } label: { Text(e).font(.system(size: 30)) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
    }

    private func toast(_ text: String) {
        toastText = text; showSent = true
        Task { try? await Task.sleep(nanoseconds: 1_300_000_000); await MainActor.run { showSent = false } }
    }
    private func flashSent() { toast("Sent") }

    // Save the currently shown story image (from the cache) to the camera roll.
    private func saveToGallery() {
        guard let s = story, let img = StoryImageCache.shared.object(forKey: s.mediaUrl as NSString) else { toast("Save failed"); return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        toast("Saved")
    }
    private func reportStory() {
        guard let s = story else { return }
        Task { await StoriesService.shared.reportStory(s) }
        toast("Reported")
    }

    // Bottom bar: "Send message…" + heart (quick ❤️) + send. Replies go to the author's chat.
    @ViewBuilder private func replyBar(_ s: Story) -> some View {
        HStack(spacing: 14) {
            TextField("Send message…", text: $replyText)
                .focused($replyFocused)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 1.5))
            Button { sendToAuthor(s, "❤️") } label: {
                Image(systemName: "heart").font(.system(size: 25)).foregroundStyle(.white)
            }
            Button {
                let t = replyText.trimmingCharacters(in: .whitespaces)
                replyText = ""; replyFocused = false
                sendToAuthor(s, t)
            } label: {
                Image(systemName: "paperplane").font(.system(size: 23)).foregroundStyle(.white)
            }
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(replyText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func deleteCurrentStory() {
        guard let s = story else { return }
        Task { await StoriesService.shared.deleteStory(s.id) }
        next()
    }

    // Send a story reply / reaction as a normal message into the author's chat (E2EE).
    private func sendToAuthor(_ s: Story, _ text: String) {
        guard !text.isEmpty, let me = AuthService.shared.uid, me != s.authorUid else { return }
        flashSent()
        let cid = [me, s.authorUid].sorted().joined(separator: "_")
        Task { try? await ChatService.sendText(cid: cid, text: text) }
    }

    private func timeAgo(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// Compose: pick a photo, preview, share to My Status. (Camera UI comes in a later stage.)
struct StoryComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var posting = false
    @State private var postError = false
    @State private var textMode = false   // text story (gradient + text)
    @State private var caption = ""       // optional caption baked onto the photo
    @State private var expiryHours: Double = 24   // 6 / 12 / 24 / 48
    @FocusState private var captionFocused: Bool
    var onPosted: () -> Void

    private var expiryLabel: String { "\(Int(expiryHours))h" }
    private func cycleExpiry() {
        expiryHours = expiryHours == 6 ? 12 : (expiryHours == 12 ? 24 : (expiryHours == 24 ? 48 : 6))
    }

    var body: some View {
        Group {
            if let data, let ui = UIImage(data: data) {
                // Instagram-style preview: full-bleed photo, caption bar, "Your story" + send.
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().ignoresSafeArea()

                    // Caption preview baked near the bottom (only when typing/has text).
                    if !caption.isEmpty {
                        VStack {
                            Spacer()
                            Text(caption)
                                .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(.black.opacity(0.32))
                            Spacer().frame(height: 150)
                        }
                        .allowsHitTesting(false)
                    }

                    VStack {
                        // top: close (also discards the photo -> back to camera)
                        HStack {
                            Button { self.data = nil; caption = "" } label: { camCircle("xmark") }
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.top, 8)

                        Spacer()

                        // caption field + expiry chip (6h / 12h / 24h / 48h)
                        HStack(spacing: 10) {
                            TextField("Add a caption…", text: $caption, axis: .vertical)
                                .focused($captionFocused)
                                .foregroundStyle(.white).tint(.white)
                                .lineLimit(1...3)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(.black.opacity(0.4), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                            Button { cycleExpiry() } label: {
                                Text(expiryLabel).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 46, height: 46)
                                    .background(.black.opacity(0.4), in: Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                            }
                        }
                        .padding(.horizontal, 14)

                        // send bar: "Your story" pill + circular send
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.fill")
                                Text("Your story").fontWeight(.semibold)
                            }
                            .font(.subheadline).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(.white.opacity(0.18), in: Capsule())
                            Spacer()
                            Button { Task { await post() } } label: {
                                Group {
                                    if posting { ProgressView().tint(.white) }
                                    else { Image(systemName: "arrow.right").font(.system(size: 22, weight: .bold)).foregroundStyle(.white) }
                                }
                                .frame(width: 54, height: 54)
                                .background(Color.accentColor, in: Circle())
                            }
                            .disabled(posting)
                        }
                        .padding(.horizontal, 14).padding(.top, 10)
                        .padding(.bottom, captionFocused ? 8 : 16)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: captionFocused)
            } else if textMode {
                StoryTextComposer(onShare: { d in Task { await postDirect(d) } },
                                  onClose: { textMode = false })
            } else {
                // Live story camera (capture / library) + Aa text-story mode.
                StoryCameraView(onCapture: { d in data = d }, onClose: { dismiss() },
                                onTextMode: { textMode = true })
            }
        }
        .alert("Couldn't share", isPresented: $postError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Your status didn't upload. Check your connection and try again.") }
    }

    private func camCircle(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white).frame(width: 42, height: 42).background(.black.opacity(0.4), in: Circle())
    }

    private func post() async {
        let img = await MainActor.run { bakedImageData() }
        guard let img else { return }
        posting = true
        do {
            try await StoriesService.shared.postStory(image: img, expiryHours: expiryHours)
            posting = false
            onPosted()
            dismiss()
        } catch {
            posting = false
            postError = true   // keep the preview so the user can retry, don't silently dismiss
        }
    }

    // Bake the caption onto the photo (so recipients see it) — else post the raw photo.
    @MainActor private func bakedImageData() -> Data? {
        guard let raw = data else { return nil }
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cap.isEmpty, let ui = UIImage(data: raw) else { return raw }
        let w = ui.size.width, h = ui.size.height
        let composed = ZStack {
            Image(uiImage: ui).resizable().scaledToFill()
            VStack {
                Spacer()
                Text(cap)
                    .font(.system(size: max(28, w * 0.045), weight: .semibold))
                    .foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(.horizontal, w * 0.05).padding(.vertical, h * 0.012)
                    .frame(maxWidth: .infinity).background(.black.opacity(0.32))
                Spacer().frame(height: h * 0.08)
            }
        }
        .frame(width: w, height: h)
        let r = ImageRenderer(content: composed); r.scale = 1
        return r.uiImage?.jpegData(compressionQuality: 0.9) ?? raw
    }

    // Post a rendered text-story image directly (no preview step).
    private func postDirect(_ d: Data) async {
        posting = true
        do {
            try await StoriesService.shared.postStory(image: d)
            posting = false; onPosted(); dismiss()
        } catch {
            posting = false; textMode = false; postError = true
        }
    }
}
