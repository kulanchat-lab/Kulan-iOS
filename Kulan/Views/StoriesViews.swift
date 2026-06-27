import SwiftUI
import PhotosUI
import Photos
import UIKit
import StoryUI

// Cached story image: memory + persistent disk (DiskImageCache), so swiping
// back/forward, reopening, and app relaunches load instantly with no re-download.
struct StoryImage: View {
    let url: String
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else if failed {
                ZStack { Color.black; Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.5)) }
            } else {
                SkeletonFill()
            }
        }
        .animation(.easeOut(duration: 0.25), value: image != nil)   // fade in when loaded
        .task(id: url) { await load() }
    }
    @MainActor private func load() async {
        failed = false
        if let cached = await DiskImageCache.shared.image(for: url) { image = cached; return }
        guard let u = URL(string: url) else { failed = true; return }
        guard let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data) else {
            failed = true; return
        }
        DiskImageCache.shared.store(img, data: data, for: url)
        image = img
    }
}

// Local per-author story prefs.
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

// Horizontal Stories row for the top of the Chats screen.
struct StoriesRow: View {
    @State private var repo = StoriesRepository.shared
    @State private var stories = StoriesService.shared   // observe the live upload state
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
    private var cardW: CGFloat {
        (UIScreen.main.bounds.width - storyHPad * 2 - storySpacing * 3) / 4
    }
    private var cardH: CGFloat { cardW * 1.46 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: storySpacing) {
                myCard
                ForEach(repo.others.filter { !StoryPrefs.isHidden($0.authorUid) }) { g in
                    card(cover: g.stories.last?.mediaUrl,
                         name: g.name.isEmpty ? "User" : g.name,
                         avatar: g.photoUrl, unseen: g.hasUnseen) { onOpen(g) }
                        // Native Apple peek: long-press lifts THIS card + shows the system menu
                        // (same as the chat rows). Works here because the row is a ScrollView, not a List.
                        .contextMenu {
                            Button { onMessage(g) } label: { Label("Send Message", systemImage: "message") }
                            Button { onProfile(g) } label: { Label("Open Profile", systemImage: "person.crop.circle") }
                            Button {
                                StoryPrefs.toggleNotify(g.authorUid); prefsTick += 1
                            } label: {
                                Label(StoryPrefs.isNotifying(g.authorUid) ? "Stop Notifying" : "Notify About Stories",
                                      systemImage: StoryPrefs.isNotifying(g.authorUid) ? "bell.slash" : "bell")
                            }
                            Button { onOpenAnon(g) } label: { Label("View Anonymously", systemImage: "eye.slash") }
                            Button(role: .destructive) {
                                StoryPrefs.toggleHidden(g.authorUid); prefsTick += 1
                            } label: { Label("Hide Stories", systemImage: "xmark.circle") }
                        }
                }
            }
            .padding(.horizontal, storyHPad)
            .padding(.vertical, 10)
        }
        .task { await repo.load() }
    }

    @ViewBuilder private var myCard: some View {
        if stories.uploading {
            uploadingCard
        } else {
            card(cover: repo.mine?.stories.last?.mediaUrl ?? mePhoto,
                 name: "My Story", avatar: mePhoto,
                 unseen: repo.mine?.hasUnseen ?? false, onBadge: onCompose) {
                if let m = repo.mine { onOpen(m) } else { onCompose() }
            }
        }
    }

    // Shown in the first slot while a story is uploading: local image + spinner ring + "Uploading…".
    private var uploadingCard: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let ui = stories.uploadingImage {
                        Image(uiImage: ui).resizable().scaledToFill()
                    } else {
                        Color(.secondarySystemFill)
                    }
                }
                .frame(width: cardW, height: cardH)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.black.opacity(0.25)))

                ZStack {
                    Spinner(size: 26, color: .white)
                }
                .padding(8)
            }
            Text("Uploading…").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
    }

    private func card(cover: String?, name: String, avatar: String?, unseen: Bool,
                      onBadge: (() -> Void)? = nil, tap: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                coverImage(cover, name: name, avatar: avatar)
                    .frame(width: cardW, height: cardH)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                if let onBadge {
                    Button(action: onBadge) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 26)).symbolRenderingMode(.palette)
                            .foregroundStyle(Color(.systemBackground), .primary)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    }
                    .buttonStyle(.plain).padding(8)
                } else {
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: unseen ? 2.5 : 0))
                        .animation(.easeInOut(duration: 0.3), value: unseen)
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
            StoryImage(url: cover)
        } else {
            ZStack {
                Color.secondary.opacity(0.2)
                AvatarView(name: name, photoUrl: avatar, size: cardW * 0.62)
            }
        }
    }

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

// MARK: - Story Viewer (Instagram-style)

// Full-screen story viewer: thin progress bars at top, Instagram-style header and
// bottom reply bar, tap-right = next / tap-left = back, hold = pause, swipe-down = close.
// Full-screen story viewer — now powered by the StoryUI library (MIT) for its native swipe,
// progress bars, tap-to-advance, hold-to-pause and reply/emoji bar. We map our StoryGroups into
// StoryUI's models and route replies/emoji/like back to the author as a DM (our existing behavior).
// NOTE: report-story / delete-my-story from inside the viewer are not exposed by StoryUI (do those
// from the story row's long-press instead). `StoryUI.Story` is qualified to avoid colliding with
// our own `Story` type.
struct StoryViewer: View {
    let groups: [StoryGroup]
    var startIndex: Int = 0
    var anonymous: Bool
    var onClose: () -> Void
    var onProfile: (StoryGroup) -> Void = { _ in }   // tap the story header → that user's profile
    @State private var isPresented = true

    init(group: StoryGroup, anonymous: Bool = false, onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in }) {
        self.init(groups: [group], startIndex: 0, anonymous: anonymous, onClose: onClose, onProfile: onProfile)
    }
    init(groups: [StoryGroup], startIndex: Int = 0, anonymous: Bool = false, onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in }) {
        self.groups = groups
        self.startIndex = startIndex
        self.anonymous = anonymous
        self.onClose = onClose
        self.onProfile = onProfile
    }

    private var models: [StoryUIModel] {
        groups.map { g in
            StoryUIModel(
                id: g.authorUid,
                user: StoryUIUser(id: g.authorUid, name: g.name, image: g.photoUrl ?? ""),
                stories: g.stories.map { s in
                    StoryUI.Story(
                        id: s.id,
                        mediaURL: s.mediaUrl,
                        date: timeAgo(s.createdAt),
                        config: StoryConfiguration(
                            storyType: s.allowsReplies
                                ? .message(config: StoryInteractionConfig(showLikeButton: true),
                                           emojis: [["❤️", "😂", "😮"], ["😢", "👏", "🔥"]],
                                           placeholder: "Send message…")
                                : .plain(),
                            mediaType: .image
                        )
                    )
                }
            )
        }
    }

    var body: some View {
        StoryView(
            stories: models,
            selectedIndex: startIndex,
            isPresented: $isPresented,
            userClosure: { story, message, emoji, isLiked in
                handle(storyId: story.id, message: message, emoji: emoji, isLiked: isLiked)
            },
            onProfile: { user in
                if let g = groups.first(where: { $0.authorUid == user.id }) { onClose(); onProfile(g) }
            }
        )
        .ignoresSafeArea()
        .onChange(of: isPresented) { _, shown in if !shown { onClose() } }
        .task { await markAllSeen() }
    }

    // Reply text / tapped emoji / like → DM the story's author (mirrors the old sendToAuthor).
    private func handle(storyId: String, message: String?, emoji: String?, isLiked: Bool) {
        let text = (message?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? emoji ?? (isLiked ? "❤️" : "")
        guard !text.isEmpty,
              let s = groups.flatMap(\.stories).first(where: { $0.id == storyId }),
              let me = AuthService.shared.uid, me != s.authorUid else { return }
        let cid = [me, s.authorUid].sorted().joined(separator: "_")
        Task { try? await ChatService.sendText(cid: cid, text: text) }
    }

    // StoryUI has no per-page callback, so mark the whole opened group seen (updates the rings).
    private func markAllSeen() async {
        guard !anonymous else { return }
        for s in groups.flatMap(\.stories) { await StoriesService.shared.markViewed(s) }
    }

    private func timeAgo(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Story Compose Sheet (photo preview + post)

struct StoryComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var posting = false
    @State private var postError = false
    @State private var postErrorMsg = ""   // surface the REAL failure (rules vs network)
    @State private var textMode = false
    @State private var caption = ""
    @State private var expiryHours: Double = 24
    @State private var kbHeight: CGFloat = 0
    @FocusState private var captionFocused: Bool
    var onPosted: () -> Void

    private var expiryLabel: String { "\(Int(expiryHours))h" }
    private func cycleExpiry() {
        expiryHours = expiryHours == 6 ? 12 : (expiryHours == 12 ? 24 : (expiryHours == 24 ? 48 : 6))
    }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom

            Group {
                if let data, let ui = UIImage(data: data) {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        Image(uiImage: ui)
                            .resizable().scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .ignoresSafeArea()

                        if !caption.isEmpty {
                            VStack {
                                Spacer()
                                Text(caption)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 18).padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .background(.black.opacity(0.32))
                                Spacer().frame(height: 160)
                            }
                            .allowsHitTesting(false)
                        }

                        VStack(spacing: 0) {
                            HStack {
                                Button {
                                    self.data = nil; caption = ""
                                } label: {
                                    camCircle("xmark")
                                }
                                .buttonStyle(.plain)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, safeTop + 8)

                            Spacer()

                            HStack(spacing: 10) {
                                TextField("Add a caption…", text: $caption, axis: .vertical)
                                    .focused($captionFocused)
                                    .foregroundStyle(.white)
                                    .tint(.white)
                                    .textFieldStyle(.plain)
                                    .lineLimit(1...3)
                                    .padding(.horizontal, 18).padding(.vertical, 12)
                                    .background(.ultraThinMaterial, in: Capsule())   // native system material

                                Button { cycleExpiry() } label: {
                                    Text(expiryLabel)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 46, height: 46)
                                        .background(.ultraThinMaterial, in: Circle())   // native system material
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)

                            HStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 17))
                                    Text("Your story")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())   // native system material

                                Spacer()

                                Button {
                                    Task { await post() }
                                } label: {
                                    ZStack {
                                        if posting {
                                            ProgressView().tint(.white)
                                        } else {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 22, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .frame(width: 56, height: 56)
                                    .background(Color.accentColor, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(posting)
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, kbHeight > 0 ? kbHeight + 8 : safeBottom + 16)
                        }
                        .animation(.easeOut(duration: 0.25), value: kbHeight)
                    }
                } else if textMode {
                    StoryTextComposer(
                        onShare: { d in Task { await postDirect(d) } },
                        onClose: { textMode = false }
                    )
                } else {
                    StoryCameraView(
                        onCapture: { d in data = d },
                        onClose: { dismiss() },
                        onTextMode: { textMode = true }
                    )
                }
            }
        }
        .ignoresSafeArea()
        .alert("Couldn't share", isPresented: $postError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(postErrorMsg.isEmpty ? "Your status didn't upload. Check your connection and try again."
                                      : postErrorMsg)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            if let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                kbHeight = max(0, UIScreen.main.bounds.height - f.origin.y)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            kbHeight = 0
        }
    }

    private func camCircle(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)   // HIG min touch target
            .background(.ultraThinMaterial, in: Circle())   // native system material
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
            postErrorMsg = error.localizedDescription
            postError = true
            print("[Story] upload failed: \(error)")
        }
    }

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
