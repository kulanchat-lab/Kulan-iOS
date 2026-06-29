import SwiftUI
import PhotosUI
import Photos
import UIKit
import StoryUI

// Telegram/IG segmented story ring: one arc per story (3 stories = 3 arcs with gaps, 1 = full circle).
// Colorful gradient when unviewed, grey when viewed. Reused on story cards AND chat-list avatars.
struct StoryRingView: View {
    let seen: [Bool]                 // per segment, oldest→newest; true = viewed (grey), false = colorful
    var lineWidth: CGFloat = 2.5
    var body: some View {
        let n = max(1, seen.count)
        let gap: CGFloat = n > 1 ? 0.045 : 0          // gap between segments (fraction of the circle)
        let seg: CGFloat = 1.0 / CGFloat(n)
        let gradient = AnyShapeStyle(AngularGradient(colors: [Color(hex: 0xF7971E), Color(hex: 0xDD2476),
                                                             Color(hex: 0x7F00FF), Color(hex: 0xF7971E)], center: .center))
        let grey = AnyShapeStyle(Color(white: 0.62))  // viewed: clearly visible grey (was too faint)
        ZStack {
            ForEach(0..<n, id: \.self) { i in
                let isSeen = i < seen.count ? seen[i] : false
                Circle()
                    .trim(from: CGFloat(i) * seg + gap / 2, to: CGFloat(i + 1) * seg - gap / 2)
                    .stroke(isSeen ? grey : gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .rotationEffect(.degrees(-90))                // first segment starts at the top
    }
}

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
    // In-memory cache so we don't re-parse the UserDefaults string on every call (seenFlags is called
    // per card per render — re-parsing each time made hide/unhide feel laggy).
    private static var cache: [String: Set<String>] = [:]
    private static func set(_ key: String) -> Set<String> {
        if let c = cache[key] { return c }
        let s = Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: " ").map(String.init))
        cache[key] = s
        return s
    }
    private static func save(_ key: String, _ s: Set<String>) {
        cache[key] = s   // update cache synchronously → instant reads
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
    // Per-STORY-ITEM seen state (drives the segmented ring: each arc greys as you view that story).
    static func isStorySeen(_ id: String) -> Bool { set("seenStoryItems").contains(id) }
    static func markStorySeen(_ id: String) {
        guard !id.isEmpty else { return }
        var s = set("seenStoryItems"); s.insert(id); save("seenStoryItems", s)
    }
    // seen flags for a bucket's stories (oldest→newest), for StoryRingView.
    static func seenFlags(_ stories: [Story]) -> [Bool] { stories.map { isStorySeen($0.id) } }
}

// Horizontal Stories row for the top of the Chats screen.
struct SeenByTarget: Identifiable { let id: String }

struct StoriesRow: View {
    @State private var repo = StoriesRepository.shared
    @State private var stories = StoriesService.shared   // observe the live upload state
    @State private var seenBy: SeenByTarget?             // "Seen by" sheet target
    var meName: String
    var mePhoto: String?
    var storyNS: Namespace.ID    // zoom transition: card ⇄ full-screen viewer
    var onCompose: () -> Void
    var onOpen: (StoryGroup) -> Void
    var onMessage: (StoryGroup) -> Void = { _ in }
    var onProfile: (StoryGroup) -> Void = { _ in }
    var onOpenAnon: (StoryGroup) -> Void = { _ in }
    @State private var prefsTick = 0   // re-render after hide/notify toggles
    @State private var hideTarget: StoryGroup?   // "Hide Stories?" confirmation target

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
                    // Each friend card is its OWN Equatable view so its long-press survives the row's
                    // re-renders (inline ForEach context menus only fired on the first card).
                    StoryFriendCard(cover: g.stories.last?.mediaUrl,
                                    name: g.name.isEmpty ? "User" : g.name,
                                    avatar: g.photoUrl,
                                    seen: StoryPrefs.seenFlags(g.stories),
                                    cardW: cardW,
                                    onOpen: { onOpen(g) },
                                    onMessage: { onMessage(g) },
                                    onProfile: { onProfile(g) },
                                    onHide: { hideTarget = g })
                        .equatable()
                }
            }
            .padding(.horizontal, storyHPad)
            .padding(.vertical, 10)
        }
        .alert("Couldn't post story", isPresented: Binding(
            get: { stories.uploadError != nil },
            set: { if !$0 { stories.uploadError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(stories.uploadError ?? "") }
        .confirmationDialog("Hide Stories?",
                            isPresented: Binding(get: { hideTarget != nil }, set: { if !$0 { hideTarget = nil } }),
                            titleVisibility: .visible, presenting: hideTarget) { g in
            Button("Hide Stories", role: .destructive) { StoryPrefs.toggleHidden(g.authorUid); prefsTick += 1; hideTarget = nil }
            Button("Cancel", role: .cancel) { hideTarget = nil }
        } message: { g in
            Text("New story updates from \(g.name.isEmpty ? "this person" : g.name) won't appear at the top of the stories list anymore.")
        }
        .task { await repo.load() }
    }

    @ViewBuilder private var myCard: some View {
        if stories.uploading {
            uploadingCard
        } else {
            card(cover: repo.mine?.stories.last?.mediaUrl ?? mePhoto,
                 name: "My Story", avatar: mePhoto,
                 seen: StoryPrefs.seenFlags(repo.mine?.stories ?? []), onBadge: onCompose) {
                if let m = repo.mine { onOpen(m) } else { onCompose() }
            }
            .contextMenu {   // My Story menu: Add Story + Posted Stories only (lifts in place, not centered)
                Button { onCompose() } label: { Label("Add Story", systemImage: "plus") }
                Button { if let m = repo.mine, !m.stories.isEmpty { onOpen(m) } }
                    label: { Label("Posted Stories", systemImage: "circle.dashed") }
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

    private func card(cover: String?, name: String, avatar: String?, seen: [Bool],
                      onBadge: (() -> Void)? = nil, tap: @escaping () -> Void) -> some View {
        // Button (not onTapGesture) so the caller's .contextMenu long-press fires reliably.
        Button(action: tap) {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                coverImage(cover, name: name, avatar: avatar)
                    .frame(width: cardW, height: cardH)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                if let onBadge {
                    // My Story: profile picture + ring (colorful before I view it, grey after) + small + badge.
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 16)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color(.systemGreen))
                                .offset(x: 4, y: 4)
                                // high-priority so tapping + adds a story without triggering the card's open tap
                                .highPriorityGesture(TapGesture().onEnded { onBadge() })
                        }
                        .animation(.easeInOut(duration: 0.3), value: seen)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                } else {
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                        .animation(.easeInOut(duration: 0.3), value: seen)
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                }
            }
            Text(name).font(.system(size: 12)).lineLimit(1).frame(width: cardW)
        }
        .frame(width: cardW)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    func reload() { Task { await repo.load(force: true) } }
}

// One friend's story card in the row. Its own Equatable view so the long-press context menu stays
// armed across the row's re-renders (the inline-ForEach version only worked on the first card).
private struct StoryFriendCard: View, Equatable {
    let cover: String?
    let name: String
    let avatar: String?
    let seen: [Bool]
    let cardW: CGFloat
    let onOpen: () -> Void
    let onMessage: () -> Void
    let onProfile: () -> Void
    let onHide: () -> Void

    static func == (l: StoryFriendCard, r: StoryFriendCard) -> Bool {
        l.cover == r.cover && l.name == r.name && l.avatar == r.avatar
            && l.seen == r.seen && l.cardW == r.cardW
    }

    private var cardH: CGFloat { cardW * 1.46 }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    coverView
                        .frame(width: cardW, height: cardH)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    AvatarView(name: name, photoUrl: avatar, size: 32)
                        .overlay { if !seen.isEmpty { StoryRingView(seen: seen).frame(width: 37, height: 37) } }
                        .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .padding(8)
                }
                Text(name).font(.system(size: 12)).lineLimit(1).frame(width: cardW)
            }
            .frame(width: cardW)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {   // lifts THIS card in place + friend menu
            Button { onMessage() } label: { Label("Send Message", systemImage: "message") }
            Button { onProfile() } label: { Label("Open Profile", systemImage: "person.crop.circle") }
            Button(role: .destructive) { onHide() } label: { Label("Hide Stories", systemImage: "archivebox") }
        }
    }

    @ViewBuilder private var coverView: some View {
        if let cover, !cover.isEmpty {
            StoryImage(url: cover)
        } else {
            ZStack { Color.secondary.opacity(0.2); AvatarView(name: name, photoUrl: avatar, size: cardW * 0.62) }
        }
    }
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
    @State private var sentToast = false   // "Sent" confirmation after a reply (WhatsApp-style)
    // Owner controls (my own story): Views/reactions/delete bar instead of the reply bar.
    @State private var currentBucketUid = ""
    @State private var currentStoryId = ""
    @State private var barViewers: [StoryViewerInfo] = []
    @State private var showViewers = false
    @State private var confirmDelete = false
    @State private var shareImg: StoryImagePayload?     // … → Share (system sheet)
    @State private var forwardImg: StoryImagePayload?   // … → Forward (chat picker)
    @State private var toastText = "Sent"               // reused for "Sent" (reply) and "Saved"
    @State private var dragDown: CGFloat = 0            // swipe-down amount → fade my overlays with the card
    private var me: String { AuthService.shared.uid ?? "" }
    private var currentIsMine: Bool { groups.first { $0.authorUid == currentBucketUid }?.isMine ?? false }
    private var myStories: [Story] { groups.first { $0.isMine }?.stories ?? [] }
    private var currentStory: Story? { groups.flatMap(\.stories).first { $0.id == currentStoryId } }

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
                            // My own story shows NO reply bar (owner bar is overlaid instead).
                            storyType: g.isMine
                                ? .plain()
                                : (s.allowsReplies
                                    ? .message(config: StoryInteractionConfig(showLikeButton: true),
                                               emojis: [["❤️", "😂", "😮"], ["😢", "👏", "🔥"]],
                                               placeholder: "Send message…")
                                    : .plain()),
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
            },
            onUserChanged: { uid in currentBucketUid = uid; markSeen(authorUid: uid); loadBarViewers() },
            onItemSeen: { id in currentStoryId = id; StoryPrefs.markStorySeen(id); markSeenItem(id); loadBarViewers() },
            onDrag: { d in dragDown = d }   // fade my overlays out as the card is pulled down
        )
        .ignoresSafeArea()
        // "…" more menu, left of the library's X (Telegram). Hidden while swiping down so it doesn't
        // float free of the card. Position is approximate — tune on device if not aligned with the X.
        .overlay(alignment: .topTrailing) {
            moreButton.padding(.top, 56).padding(.trailing, 64)
                .opacity(dragDown > 6 ? 0 : 1).animation(.easeOut(duration: 0.15), value: dragDown > 6)
        }
        // My own story: Telegram owner bar (Views + reactions + delete) instead of a reply bar.
        .overlay(alignment: .bottom) {
            if currentIsMine { ownerBar.opacity(dragDown > 6 ? 0 : 1).animation(.easeOut(duration: 0.15), value: dragDown > 6) }
        }
        .sheet(isPresented: $showViewers) {
            StoryViewersSheet(stories: myStories, selectedId: currentStoryId)
        }
        .sheet(item: $shareImg) { p in ActivityView(items: [p.image]) }
        .sheet(item: $forwardImg) { p in StoryForwardSheet(image: p.image, onSent: { flashSentToast() }) }
        .confirmationDialog("Delete this story?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteCurrent() } }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(alignment: .bottom) {
            if sentToast {
                Text(toastText)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: isPresented) { _, shown in if !shown { onClose() } }
        .presentationBackground(.clear)   // see-through cover so the Chats list shows behind during swipe-down
    }

    private func flashSentToast(_ text: String = "Sent") {
        toastText = text
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { sentToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.25)) { sentToast = false }
        }
    }

    // "…" more menu: actions differ for my story vs someone else's.
    private var moreButton: some View {
        Menu {
            // My own story: delete lives in the owner bar (views + delete), so "⋯" is just Save/Forward/Share.
            if !currentIsMine {
                Button { StoryPrefs.toggleHidden(currentBucketUid); isPresented = false } label: {
                    Label("Hide Stories", systemImage: "archivebox")
                }
            }
            Button { saveCurrentImage() } label: { Label("Save", systemImage: "square.and.arrow.down") }
            Button { Task { if let img = await loadCurrentImage() { forwardImg = StoryImagePayload(image: img) } } }
                label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            Button { Task { if let img = await loadCurrentImage() { shareImg = StoryImagePayload(image: img) } } }
                label: { Label("Share", systemImage: "square.and.arrow.up") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(.white.opacity(0.18), in: Circle())
        }
    }

    private func loadCurrentImage() async -> UIImage? {
        guard let url = currentStory?.mediaUrl, !url.isEmpty else { return nil }
        if let m = DiskImageCache.shared.memoryImage(url) { return m }
        return await DiskImageCache.shared.image(for: url)
    }

    private func saveCurrentImage() {
        Task {
            guard let img = await loadCurrentImage() else { return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { return }
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                flashSentToast("Saved")
            }
        }
    }

    // Reply text / tapped emoji / like → DM the story's author (mirrors the old sendToAuthor).
    private func handle(storyId: String, message: String?, emoji: String?, isLiked: Bool) {
        let text = (message?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? emoji ?? (isLiked ? "❤️" : "")
        guard !text.isEmpty,
              let s = groups.flatMap(\.stories).first(where: { $0.id == storyId }),
              let me = AuthService.shared.uid, me != s.authorUid else { return }
        let cid = [me, s.authorUid].sorted().joined(separator: "_")
        // Attach the status reference so the reply shows as a "Status" quote (thumbnail) in chat.
        let ref = ReplyRef(id: s.id, authorId: s.authorUid, text: "", isStatus: true, storyThumbUrl: s.mediaUrl)
        let isReaction = (message?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty && (emoji != nil || isLiked)
        Task {
            try? await ChatService.sendText(cid: cid, text: text, replyTo: ref)
            if isReaction { await StoriesService.shared.setStoryReaction(s, emoji: text) }   // shows in "Seen by"
        }
        flashSentToast()   // optimistic "Sent" confirmation (WhatsApp-style)
    }

    // Landing on a person clears THEIR ring (not everyone's). Per-photo receipts are sent
    // separately by markSeenItem, so we no longer receipt photos the viewer never reached.
    private func markSeen(authorUid: String) {
        guard !anonymous else { return }
        StoriesRepository.shared.markSeenLocally(authorUid)   // clear the ring immediately (H8 race fix)
    }

    // Receipt ONLY the photo actually shown (drives accurate view counts + "Seen by").
    private func markSeenItem(_ storyId: String) {
        guard !anonymous, let s = groups.flatMap(\.stories).first(where: { $0.id == storyId }) else { return }
        Task { await StoriesService.shared.markViewed(s) }
    }

    private func timeAgo(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    // Telegram owner bar: overlapping viewer avatars + "N Views" + ❤️ reactions (tap → sheet) + delete.
    private var ownerBar: some View {
        let reactions = barViewers.filter { !($0.reaction ?? "").isEmpty }.count
        return HStack(spacing: 12) {
            Button { showViewers = true } label: {
                HStack(spacing: 8) {
                    if !barViewers.isEmpty {
                        HStack(spacing: -8) {
                            ForEach(barViewers.prefix(3)) { v in
                                AvatarView(name: v.name, photoUrl: v.photoUrl, size: 26)
                                    .overlay(Circle().stroke(.black, lineWidth: 1.5))
                            }
                        }
                    } else {
                        Image(systemName: "eye").font(.subheadline).foregroundStyle(.white)
                    }
                    Text("\(barViewers.count) View\(barViewers.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    if reactions > 0 {
                        Image(systemName: "heart.fill").font(.subheadline).foregroundStyle(.red)
                        Text("\(reactions)").font(.subheadline).foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { confirmDelete = true } label: {
                Image(systemName: "trash").font(.title3).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 20)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
    }

    private func loadBarViewers() {
        guard currentIsMine, !currentStoryId.isEmpty else { return }
        let id = currentStoryId
        Task {
            let v = await StoriesService.shared.fetchViewers(storyId: id)
            if id == currentStoryId { barViewers = v }
        }
    }

    private func deleteCurrent() async {
        guard !currentStoryId.isEmpty else { return }
        await StoriesService.shared.deleteStory(currentStoryId)
        await StoriesRepository.shared.load(force: true)
        onClose()
    }
}

// "Seen by" sheet — who viewed my status (premium, like WhatsApp/IG).
struct SeenBySheet: View {
    let storyId: String
    @Environment(\.dismiss) private var dismiss
    @State private var viewers: [StoryViewerInfo] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewers.isEmpty {
                    ContentUnavailableView("No views yet", systemImage: "eye",
                        description: Text("When people view your status, they'll appear here."))
                } else {
                    List(viewers) { v in
                        HStack(spacing: 12) {
                            AvatarView(name: v.name, photoUrl: v.photoUrl, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name).font(.body)
                                Text(v.viewedAt, format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let r = v.reaction, !r.isEmpty { Text(r).font(.title3) }
                        }
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(viewers.isEmpty ? "Seen by" : "Seen by \(viewers.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task {
            viewers = await StoriesService.shared.fetchViewers(storyId: storyId)
            loading = false
        }
    }
}


// Telegram-style story viewers sheet: horizontal cards of my stories (with view/❤️ counts),
// All-Viewers/Contacts segmented control, search, and a viewer list (avatar, name, time, heart).
struct StoryViewersSheet: View {
    let stories: [Story]
    let selectedId: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String = ""
    @State private var scrolledID: String?   // carousel-centered card → drives `selected`
    @State private var byStory: [String: [StoryViewerInfo]] = [:]
    @State private var segment = 0          // 0 = All Viewers, 1 = Contacts
    @State private var search = ""
    @State private var loading = true

    private var me: String { AuthService.shared.uid ?? "" }
    private var contactUids: Set<String> {
        Set(ConversationsRepository.shared.conversations.compactMap { $0.isGroup ? nil : $0.otherUid(me) })
    }
    private var viewers: [StoryViewerInfo] {
        var v = byStory[selected] ?? []
        if segment == 1 { v = v.filter { contactUids.contains($0.id) } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { v = v.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        return v
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(stories, id: \.id) { s in storyCard(s) }   // each scales by distance from center
                }
                .scrollTargetLayout()
                .padding(.horizontal, max(16, (UIScreen.main.bounds.width - 150) / 2))   // center the focused card
                .padding(.vertical, 8)
            }
            .scrollTargetBehavior(.viewAligned)                      // snaps to each card
            .scrollPosition(id: $scrolledID)                         // centered card → auto-select
            .frame(height: 290)

            Picker("", selection: $segment) {
                Text("All Viewers").tag(0)
                Text("Contacts").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .padding(.horizontal, 16).padding(.bottom, 8)

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewers.isEmpty {
                ContentUnavailableView("No viewers", systemImage: "eye",
                                       description: Text("No one in this list yet."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewers) { v in viewerRow(v) }
                    .listStyle(.plain)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: scrolledID) { _, v in if let v { selected = v } }   // centered card drives the viewer list
        .task { await loadAll() }
    }

    private func storyCard(_ s: Story) -> some View {
        let vs = byStory[s.id] ?? []
        let reacts = vs.filter { !($0.reaction ?? "").isEmpty }.count
        let w: CGFloat = 150, h: CGFloat = 258
        return GeometryReader { geo in
            // Scale by how close this card's centre is to the screen centre: centre = full, sides shrink.
            let screenMid = UIScreen.main.bounds.width / 2
            let dist = abs(geo.frame(in: .global).midX - screenMid)
            let scale = max(0.72, 1 - dist / 600)
            StoryImage(url: s.mediaUrl)
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))   // iOS 26 generous corners
                .overlay(alignment: .bottom) {
                    HStack(spacing: 5) {
                        Image(systemName: "eye.fill").font(.caption2)
                        Text("\(vs.count)").font(.caption2.weight(.semibold))
                        if reacts > 0 {
                            Image(systemName: "heart.fill").font(.caption2).foregroundStyle(.red)
                            Text("\(reacts)").font(.caption2.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 10)
                }
                .scaleEffect(scale)
                .opacity(Double(max(0.6, scale)))                // sides also dim slightly
                .frame(maxWidth: .infinity, maxHeight: .infinity)  // centre the scaled card in its slot
        }
        .frame(width: w, height: h)
        .id(s.id)
        // Springy physics: tapping a side card springs it to centre (momentum/snap on free-scroll is native).
        .onTapGesture { withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { scrolledID = s.id } }
    }

    private func viewerRow(_ v: StoryViewerInfo) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: v.name, photoUrl: v.photoUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(.body)
                Text(dateFmt(v.viewedAt)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let r = v.reaction, !r.isEmpty {
                Image(systemName: "heart.fill").foregroundStyle(.red).font(.title3)
            }
        }
        .listRowSeparator(.hidden)
    }

    private func dateFmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy 'at' h:mm a"
        return f.string(from: d)
    }

    private func loadAll() async {
        selected = selectedId.isEmpty ? (stories.last?.id ?? "") : selectedId
        scrolledID = selected   // start the carousel centered on the tapped story
        await withTaskGroup(of: (String, [StoryViewerInfo]).self) { group in
            for s in stories { group.addTask { (s.id, await StoriesService.shared.fetchViewers(storyId: s.id)) } }
            for await (id, v) in group { byStory[id] = v }
        }
        loading = false
    }
}

// Wrapper so a UIImage can drive a .sheet(item:).
struct StoryImagePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

// Forward a story image to one or more chats. sendImage re-encrypts per chat (and auto-fetches
// group members), so this works for 1:1 and groups. Real send pipeline — no fakes.
struct StoryForwardSheet: View {
    let image: UIImage
    var onSent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var sending = false
    private var me: String { AuthService.shared.uid ?? "" }

    private var people: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = repo.conversations.filter { ($0.isGroup || !$0.otherUid(me).isEmpty) && !$0.isCleared(me) }
        return (q.isEmpty ? list : list.filter { $0.displayName(me).lowercased().contains(q) })
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    var body: some View {
        NavigationStack {
            List(people) { c in
                Button {
                    if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: c.displayName(me), photoUrl: c.displayPhoto(me), size: 44)
                        Text(c.displayName(me)).font(.body)
                        Spacer()
                        Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(c.id) ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(sending ? "Sending…" : "Send") { send() }
                        .disabled(selected.isEmpty || sending).fontWeight(.semibold)
                }
            }
        }
    }

    private func send() {
        guard let data = image.jpegData(compressionQuality: 0.9), !selected.isEmpty else { return }
        sending = true
        let ids = Array(selected)
        Task {
            for cid in ids { try? await ChatService.sendImage(cid: cid, data: data) }
            await MainActor.run { dismiss(); onSent() }
        }
    }
}
