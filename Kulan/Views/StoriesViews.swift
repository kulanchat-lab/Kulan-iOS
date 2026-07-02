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
        // Unviewed: green→blue gradient (Telegram/WhatsApp style). Viewed: a real medium grey (the old
        // 0.62 read as white on the dark card).
        let gradient = AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x34C759), Color(hex: 0x0A84FF)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
        let grey = AnyShapeStyle(Color(white: 0.46))
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
    // LOCKED: hasUnseen (→ isStorySeen) now also runs inside StoriesRepository.rebuild() on
    // background cooperative threads — three listeners fire together at launch, and concurrent
    // cache-miss writes to this static dictionary corrupted it (SIGSEGV on every cold start, 177).
    private static var cache: [String: Set<String>] = [:]
    private static let lock = NSLock()
    private static func set(_ key: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let s = Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: " ").map(String.init))
        cache[key] = s
        return s
    }
    private static func save(_ key: String, _ s: Set<String>) {
        lock.lock(); cache[key] = s; lock.unlock()   // update cache synchronously → instant reads
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
    // My own ❤️ on a story — persists so the heart is still red on reopen (Instagram).
    static func isStoryLiked(_ id: String) -> Bool { set("likedStories").contains(id) }
    static func setStoryLiked(_ id: String, _ liked: Bool) {
        guard !id.isEmpty else { return }
        var s = set("likedStories"); if liked { s.insert(id) } else { s.remove(id) }; save("likedStories", s)
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
    var onOpenUploading: () -> Void = {}   // tap the still-uploading card → live upload viewer
    @State private var prefsTick = 0   // re-render after hide/notify toggles
    @State private var hideTarget: StoryGroup?   // "Hide Stories?" confirmation target

    private let storySpacing: CGFloat = 10
    private let storyHPad: CGFloat = 12
    private var cardW: CGFloat {
        (UIScreen.main.bounds.width - storyHPad * 2 - storySpacing * 3) / 4
    }
    private var cardH: CGFloat { cardW * 1.46 }

    // Ordering (WhatsApp): UNVIEWED first, then VIEWED — BOTH sorted by newest post first (never
    // by when I watched). Re-sorts live (no reload) the instant a person's last unseen story is
    // watched (markSeenLocally advances the watermark) and the cards animate.
    private var orderedOthers: [StoryGroup] {
        let _ = prefsTick   // re-evaluate after hide/seen toggles
        func newestFirst(_ a: StoryGroup, _ b: StoryGroup) -> Bool {
            (a.stories.last?.createdAt ?? .distantPast) > (b.stories.last?.createdAt ?? .distantPast)
        }
        let visible = repo.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        let unviewed = visible.filter { $0.hasUnseen }.sorted(by: newestFirst)
        let viewed = visible.filter { !$0.hasUnseen }.sorted(by: newestFirst)
        return unviewed + viewed
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: storySpacing) {
                myCard
                    .id("my-story")   // STABLE identity so its "Add Story/Posted Stories" menu never binds
                                      // to a friend card when the row re-sorts (SwiftUI context-menu bug).
                ForEach(orderedOthers) { g in
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
                                    onHide: { hideTarget = g },
                                    storyNS: storyNS,
                                    groupID: g.id)
                        .equatable()
                        .id(g.authorUid)   // explicit stable identity → its menu stays bound to this person
                }
            }
            .padding(.horizontal, storyHPad)
            .padding(.vertical, 10)
            // Smoothly slide cards to their new spots when a story moves unviewed -> viewed-front (no reload).
            .animation(.spring(response: 0.42, dampingFraction: 0.82), value: orderedOthers.map(\.id))
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
        // ZStack + crossfade so the "Uploading…" placeholder morphs straight into the final card in the
        // same frame (no jump). The reload happens before `uploading` flips, so there's no stale image.
        ZStack {
            if stories.uploading {
                uploadingCard.transition(.opacity)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenUploading() }   // tappable even while uploading → live viewer
            } else {
                card(cover: repo.mine?.stories.last?.mediaUrl ?? mePhoto,
                     name: "My Story", avatar: mePhoto,
                     seen: StoryPrefs.seenFlags(repo.mine?.stories ?? []), onBadge: onCompose) {
                    if let m = repo.mine { onOpen(m) } else { onCompose() }
                }
                .contextMenu {   // My Story menu: Add Story + Posted Stories only (lifts in place — build 147)
                    Button { onCompose() } label: { Label("Add Story", systemImage: "plus") }
                    Button { if let m = repo.mine, !m.stories.isEmpty { onOpen(m) } }
                        label: { Label("Posted Stories", systemImage: "circle.dashed") }
                }
                .matchedTransitionSource(id: repo.mine?.id ?? "my-story", in: storyNS)   // hero grow source
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stories.uploading)
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
                    AvatarView(name: meName, photoUrl: mePhoto, size: 32)   // my profile avatar in the center
                    Spinner(size: 37, color: .white)                        // ring hugs the avatar like the story rings (37)
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
    let storyNS: Namespace.ID    // hero zoom: card ⇄ viewer
    let groupID: String          // matches the viewer's zoom sourceID

    static func == (l: StoryFriendCard, r: StoryFriendCard) -> Bool {
        l.cover == r.cover && l.name == r.name && l.avatar == r.avatar
            && l.seen == r.seen && l.cardW == r.cardW && l.groupID == r.groupID
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
        .contextMenu {   // lifts THIS card in place + friend menu (default lift — build 147)
            Button { onMessage() } label: { Label("Send Message", systemImage: "message") }
            Button { onProfile() } label: { Label("Open Profile", systemImage: "person.crop.circle") }
            Button(role: .destructive) { onHide() } label: { Label("Hide Stories", systemImage: "archivebox") }
        }
        .matchedTransitionSource(id: groupID, in: storyNS)   // hero grow source
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
    var onDeletedRemaining: (StoryGroup) -> Void = { _ in }   // deleted an item but more of mine remain → re-feed
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
    @State private var profileSheet: StoryGroup?        // tap the header → profile sheet OVER the story (paused)
    @State private var toastText = "Sent"               // reused for "Sent" (reply) and "Saved"
    @State private var dragDown: CGFloat = 0            // swipe-down amount → fade my overlays with the card
    private var me: String { AuthService.shared.uid ?? "" }
    private var currentIsMine: Bool { groups.first { $0.authorUid == currentBucketUid }?.isMine ?? false }
    // Home-indicator inset (the story ignoresSafeArea, so overlays must add it back themselves).
    private var bottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.max() ?? 0
    }
    private var currentStory: Story? { groups.flatMap(\.stories).first { $0.id == currentStoryId } }
    // Any sheet shown over the story → pause it (viewers list, share, forward, "…" menu, delete confirm).
    private var sheetUp: Bool { showViewers || shareImg != nil || forwardImg != nil || confirmDelete || profileSheet != nil }

    init(group: StoryGroup, anonymous: Bool = false, onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.init(groups: [group], startIndex: 0, anonymous: anonymous, onClose: onClose, onProfile: onProfile,
                  onDeletedRemaining: onDeletedRemaining)
    }
    init(groups: [StoryGroup], startIndex: Int = 0, anonymous: Bool = false, onClose: @escaping () -> Void,
         onProfile: @escaping (StoryGroup) -> Void = { _ in },
         onDeletedRemaining: @escaping (StoryGroup) -> Void = { _ in }) {
        self.groups = groups
        self.startIndex = startIndex
        self.anonymous = anonymous
        self.onClose = onClose
        self.onProfile = onProfile
        self.onDeletedRemaining = onDeletedRemaining
    }

    private var models: [StoryUIModel] {
        groups.map { g in
            StoryUIModel(
                id: g.authorUid,
                user: StoryUIUser(id: g.authorUid, name: g.name, image: g.photoUrl ?? ""),
                isMine: g.isMine,   // drives the "…" menu: my story shows Delete, others show Hide Stories
                stories: g.stories.map { s in
                    StoryUI.Story(
                        id: s.id,
                        mediaURL: s.mediaUrl,
                        date: timeAgo(s.createdAt),
                        isLiked: StoryPrefs.isStoryLiked(s.id),   // heart stays red on reopen
                        isSeen: StoryPrefs.isStorySeen(s.id),   // open the viewer at the first UNSEEN item
                        caption: s.caption,
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
        ZStack {
            // Solid black canvas revealed behind the story as it scales down into a card (Telegram).
            // Invisible at rest so the see-through swipe-down dismiss (clear cover) keeps working.
            Color.black.ignoresSafeArea()
                .opacity(Double(min(viewersProgress * 3, 1)))
            storyLayer
            // The viewers sheet is a SIBLING layer, NOT a system .sheet: a system sheet lives in
            // its own presentation layer and cannot drive a continuous transform on the story
            // behind it — that limitation is what pushed the old design to render story cards
            // INSIDE the sheet. Both layers share `viewersProgress`, so the drag and the release
            // spring stay perfectly in sync.
            if showViewers {
                StoryViewersBottomSheet(activeStoryId: currentStoryId,
                                        progress: $viewersProgress,
                                        onClose: closeViewers)
            }
        }
        .sheet(item: $shareImg) { p in ActivityView(items: [p.image]) }
        .sheet(item: $forwardImg) { p in StoryForwardSheet(image: p.image, onSent: { flashSentToast() }) }
        .sheet(item: $profileSheet) { g in
            NavigationStack {
                ContactInfoView(cid: [me, g.authorUid].sorted().joined(separator: "_"),
                                name: g.name, photoUrl: g.photoUrl, isSelf: g.authorUid == me)
            }
            .presentationDetents([.medium, .large])   // small profile sheet over the paused story
            .presentationDragIndicator(.visible)
        }
        // Native-style bottom action sheets. (confirmationDialog rendered CENTERED over the cover's clear
        // presentation background; this anchors to the bottom with a material group + a separate Cancel.)
        // Delete stays a bottom action sheet; the "…" is now a native dropdown menu in the header.
        .overlay {
            if confirmDelete {
                BottomActionSheet(onCancel: { confirmDelete = false }) {
                    // Seamless delete: the viewer slides to the adjacent item itself; we just remove from the db.
                    sheetButton("Delete", destructive: true) {
                        confirmDelete = false
                        NotificationCenter.default.post(name: .init("deleteCurrentStoryItem"), object: nil)
                    }
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: confirmDelete)
        // The viewer dropped the item in-place + advanced; here we delete it from the database. If that was
        // my last story, close the viewer (Case 3). Otherwise leave the (captured) viewer untouched — no re-feed.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyItemDeleted"))) { note in
            guard let id = note.object as? String, !id.isEmpty else { return }
            Task {
                await StoriesService.shared.deleteStory(id)
                await StoriesRepository.shared.load(force: true)
                if StoriesRepository.shared.mine?.stories.isEmpty ?? true { onClose() }
            }
        }
        // "…" dropdown menu actions (posted from the library header Menu) — run on LIVE state here.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionSave"))) { _ in
            saveCurrentImage(currentStory?.mediaUrl)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionForward"))) { _ in
            let u = currentStory?.mediaUrl
            Task { if let img = await loadCurrentImage(u) { forwardImg = StoryImagePayload(image: img) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionShare"))) { _ in
            let u = currentStory?.mediaUrl
            Task { if let img = await loadCurrentImage(u) { shareImg = StoryImagePayload(image: img) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionHide"))) { _ in
            if !currentIsMine { StoryPrefs.toggleHidden(currentBucketUid); isPresented = false }
        }
        // "…" → Delete Story (only shown on my own story) → same confirm + seamless delete as the trash button.
        .onReceive(NotificationCenter.default.publisher(for: .init("storyActionDelete"))) { _ in
            if currentIsMine { confirmDelete = true }
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
        // Safety net: never leave a story paused after the viewer goes away (the swipe-down dismiss posts
        // pauseStory and does not resume on commit; a sheet up at teardown can also skip the resume).
        .onDisappear { NotificationCenter.default.post(name: .init("resumeStory"), object: nil) }
        // Freeze the running story + progress while any sheet is shown over it; resume on dismiss.
        .onChange(of: sheetUp) { _, up in
            NotificationCenter.default.post(name: up ? .init("pauseStory") : .init("resumeStory"), object: nil)
        }
        .presentationBackground(.clear)   // see-through cover so the Chats list shows behind during swipe-down
    }

    // The Active Story layer: media + header + progress bars + owner bar, exactly as before.
    // The viewers sheet's `viewersProgress` drives its transform (full screen 0 → floating card 1);
    // NO story media ever renders inside the sheet itself (the old architecture mistake).
    private var storyLayer: some View {
        let p = viewersProgress
        return StoryView(
            stories: models,
            selectedIndex: startIndex,
            isPresented: $isPresented,
            userClosure: { story, message, emoji, isLiked in
                handle(storyId: story.id, message: message, emoji: emoji, isLiked: isLiked)
            },
            onProfile: { user in
                // Open the profile OVER the story (paused) — do NOT close the viewer.
                if let g = groups.first(where: { $0.authorUid == user.id }) { profileSheet = g }
            },
            // Landing on a person no longer greys their whole ring — seen state advances per ITEM
            // below (WhatsApp rule: the ring stays colored until every story is watched).
            onUserChanged: { uid in currentBucketUid = uid; loadBarViewers() },
            // Anonymous viewing leaves NO trace (Telegram-incognito): no local flags either.
            onItemSeen: { id in
                currentStoryId = id
                if !anonymous { StoryPrefs.markStorySeen(id) }
                markSeenItem(id); loadBarViewers()
            },
            onDrag: { d in dragDown = d },   // fade my overlays out as the card is pulled down
            showMore: true, // "…" is a native dropdown menu in the header; its buttons post notifications
            onSwipeUp: { if currentIsMine { openViewers() } }  // Telegram: swipe up opens your viewers
        )
        .ignoresSafeArea()
        // My own story: Telegram owner bar (Views + reactions + delete) instead of a reply bar.
        // Lives INSIDE the transformed layer, so it shrinks with the card (Telegram's mini count bar).
        .overlay(alignment: .bottom) {
            if currentIsMine {
                ownerBar
                    .opacity(dragDown > 6 ? 0 : 1).animation(.easeOut(duration: 0.15), value: dragDown > 6)
                    .contentShape(Rectangle())
                    // Reliable swipe-up to open viewers: this owner bar is a SwiftUI overlay ON TOP of the
                    // story, so its gesture fires even when the library's UIKit swipe-up doesn't. Taps on
                    // Views/trash still work (minimumDistance gate).
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 16).onEnded { v in
                            if v.translation.height < -30 { openViewers() }
                        }
                    )
            }
        }
        // While the sheet is up, taps on the card collapse it back to full screen (Telegram) —
        // this also shields the story's own tap-to-advance/X from firing underneath.
        .overlay {
            if showViewers {
                Color.clear.contentShape(Rectangle()).onTapGesture { closeViewers() }
            }
        }
        // The Telegram effect, all driven by the ONE shared progress value:
        .clipShape(RoundedRectangle(cornerRadius: 34 * p, style: .continuous))   // 0 → rounded card
        .scaleEffect(1 - (1 - viewersFitScale) * p, anchor: .top)               // 100% → fits above sheet
        .offset(y: p * (topInset + 8))                                          // card top clears the status bar
    }

    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.max() ?? 0
    }
    // Final card scale derived from the layout (NOT a magic number): whatever exactly fills the
    // space between the status bar and the open sheet's top edge, with a small gap.
    private var viewersFitScale: CGFloat {
        let h = UIScreen.main.bounds.height
        let sheetH = h * StoryViewersBottomSheet.heightFraction
        return max(0.3, (h - topInset - 8 - 14 - sheetH) / h)
    }

    private func openViewers() {
        guard currentIsMine, !showViewers else { return }
        showViewers = true   // mount the sheet at progress 0 (offscreen) …
        DispatchQueue.main.async {   // … then slide it up on the next tick so insertion animates
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { viewersProgress = 1 }
        }
    }
    private func closeViewers() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { viewersProgress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            if viewersProgress == 0 { showViewers = false }   // unmount only if a re-open didn't interrupt
        }
    }

    private func flashSentToast(_ text: String = "Sent") {
        toastText = text
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { sentToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.25)) { sentToast = false }
        }
    }


    // Pass an explicit url (captured synchronously at button-tap) so a story that advances in the gap
    // after the "…" dialog closes can't swap the photo out from under Save/Forward/Share.
    @ViewBuilder private func sheetButton(_ title: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(destructive ? .semibold : .regular))
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity).frame(height: 56)
                .contentShape(Rectangle())
        }
    }

    private func loadCurrentImage(_ captured: String? = nil) async -> UIImage? {
        guard let url = captured ?? currentStory?.mediaUrl, !url.isEmpty else { return nil }
        if let m = DiskImageCache.shared.memoryImage(url) { return m }
        return await DiskImageCache.shared.image(for: url)
    }

    private func saveCurrentImage(_ captured: String? = nil) {
        Task {
            guard let img = await loadCurrentImage(captured) else { return }
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
        let typed = (message?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        guard let s = groups.flatMap(\.stories).first(where: { $0.id == storyId }),
              let me = AuthService.shared.uid, me != s.authorUid else { return }

        // Pure like-button toggle (no text, no picker emoji): remember it locally so the heart
        // is still red when the story is reopened (Instagram). Un-like removes my reaction from
        // the author's "Seen by" and sends nothing.
        if typed == nil && emoji == nil {
            StoryPrefs.setStoryLiked(storyId, isLiked)
            if !isLiked {
                Task { await StoriesService.shared.clearStoryReaction(s) }
                return
            }
        }

        let text = typed ?? emoji ?? (isLiked ? "❤️" : "")
        guard !text.isEmpty else { return }
        let cid = [me, s.authorUid].sorted().joined(separator: "_")
        // Attach the status reference so the reply shows as a "Status" quote (thumbnail) in chat.
        let ref = ReplyRef(id: s.id, authorId: s.authorUid, text: "", isStatus: true, storyThumbUrl: s.mediaUrl)
        let isReaction = typed == nil && (emoji != nil || isLiked)
        Task {
            try? await ChatService.sendText(cid: cid, text: text, replyTo: ref)
            if isReaction { await StoriesService.shared.setStoryReaction(s, emoji: text) }   // shows in "Seen by"
        }
        flashSentToast()   // optimistic "Sent" confirmation (WhatsApp-style)
    }

    // Receipt ONLY the photo actually shown (drives accurate view counts + "Seen by"), and
    // advance the local watermark so the ring/row update instantly (H8 race fix).
    private func markSeenItem(_ storyId: String) {
        guard !anonymous, let s = groups.flatMap(\.stories).first(where: { $0.id == storyId }) else { return }
        StoriesRepository.shared.markSeenLocally(s.authorUid, upTo: s.createdAt)
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
            Button { openViewers() } label: {
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
        // Smooth, gradual shadow: a tall gradient that eases clear -> black so it blends softly into the photo
        // (no hard edge), with the controls on the solid part at the bottom.
        .padding(.horizontal, 18).padding(.top, 64).padding(.bottom, max(22, bottomInset + 10))
        .background(LinearGradient(stops: [
            .init(color: .clear,                 location: 0.0),
            .init(color: .black.opacity(0.35),   location: 0.45),
            .init(color: .black.opacity(0.85),   location: 0.78),
            .init(color: .black,                 location: 1.0)
        ], startPoint: .top, endPoint: .bottom))
    }

    private func loadBarViewers() {
        guard currentIsMine, !currentStoryId.isEmpty else { return }
        let id = currentStoryId
        Task {
            let v = await StoriesService.shared.fetchViewers(storyId: id)
            if id == currentStoryId { barViewers = v }
        }
    }

}

// Live viewer for a story that's STILL uploading: renders the local image full-screen with an "Uploading…"
// status bar (X · spinner · label · trash). Listens to the upload state; when it finishes successfully it
// hands off to the real story viewer automatically.
struct UploadingStoryViewer: View {
    var meName: String
    var mePhoto: String?
    var onClose: () -> Void
    var onFinished: () -> Void          // upload succeeded → open the real story viewer
    @State private var stories = StoriesService.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let img = stories.uploadingImage {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(   // top scrim so the header stays readable on bright photos
                        LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 130).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false),
                        alignment: .top)
            }
            VStack {
                HStack(spacing: 10) {
                    AvatarView(name: meName, photoUrl: mePhoto, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your story").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text("just now").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
                // Bottom upload status bar: X (close) · spinner · "Uploading…" · trash (cancel).
                HStack(spacing: 14) {
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    }
                    Spinner(size: 20, color: .white)
                    Text("Uploading…").font(.subheadline).foregroundStyle(.white)
                    Spacer()
                    Button { stories.cancelUpload(); onClose() } label: {
                        Image(systemName: "trash").font(.system(size: 18)).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(Color.black)
            }
        }
        .onChange(of: stories.uploading) { _, up in
            guard !up else { return }   // upload finished
            if stories.uploadError == nil { onFinished() } else { onClose() }
        }
        .onAppear { if !stories.uploading { onFinished() } }   // finished before we even opened
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
// Native-style bottom action sheet: dim scrim + a material action group + a separate Cancel pill,
// anchored to the bottom (replaces confirmationDialog, which rendered centered over the clear cover).
struct BottomActionSheet<Content: View>: View {
    let onCancel: () -> Void
    @ViewBuilder let content: Content
    init(onCancel: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onCancel = onCancel
        self.content = content()
    }
    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom }.max() ?? 0
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.32).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            VStack(spacing: 8) {
                VStack(spacing: 0) { content }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button(action: onCancel) {
                    Text("Cancel").font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity).frame(height: 56).contentShape(Rectangle())
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, max(10, bottomSafeInset))   // clear the home indicator (host ignores safe area)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// Telegram-architecture viewers sheet: a SEPARATE bottom layer holding ONLY the drag handle, sticky tabs,
// search, and the scrollable viewer list — NO story media. It drives `progress` (0 closed … 1 open); the
// StoryViewer reads that to scale/round/lift the active story behind it. Both layers share one value → in sync.
struct StoryViewersBottomSheet: View {
    // Sheet height as a fraction of the screen. The story viewer derives the card's final
    // scale from this same value, so the two layers always agree on the layout (Telegram
    // sizing: sheet ≈ bottom third, card fills the space above it).
    static let heightFraction: CGFloat = 0.38

    let activeStoryId: String
    @Binding var progress: CGFloat
    let onClose: () -> Void

    @State private var viewers: [StoryViewerInfo] = []
    @State private var segment = 0          // 0 = All Viewers, 1 = Contacts
    @State private var search = ""
    @State private var loading = true
    @State private var dragStart: CGFloat? = nil

    private var me: String { AuthService.shared.uid ?? "" }
    private var contactUids: Set<String> {
        Set(ConversationsRepository.shared.conversations.compactMap { $0.isGroup ? nil : $0.otherUid(me) })
    }
    private var filtered: [StoryViewerInfo] {
        var v = viewers
        if segment == 1 { v = v.filter { contactUids.contains($0.id) } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { v = v.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        return v.sorted { $0.viewedAt > $1.viewedAt }
    }

    var body: some View {
        GeometryReader { geo in
            let sheetH = geo.size.height * Self.heightFraction
            VStack(spacing: 0) {
                stickyHeader(sheetH: sheetH)        // drag handle + tabs + search (does NOT scroll)
                viewerList                          // the only scrolling part
            }
            .frame(height: sheetH)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
                    .fill(Color(white: 0.10))
            )
            .frame(maxHeight: .infinity, alignment: .bottom)   // park at the bottom of the screen
            .offset(y: (1 - progress) * sheetH)                // slide up/down with progress
        }
        .ignoresSafeArea()
        .task(id: activeStoryId) { await load() }
    }

    // Sticky header (handle + tabs + search). Dragging here drives `progress`; the list below scrolls on its own.
    private func stickyHeader(sheetH: CGFloat) -> some View {
        VStack(spacing: 12) {
            Capsule().fill(.white.opacity(0.28)).frame(width: 38, height: 5).padding(.top, 8)
            HStack(spacing: 8) { Spacer(); tabPill("All Viewers", 0); tabPill("Contacts", 1); Spacer() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("", text: $search, prompt: Text("Search").foregroundColor(.white.opacity(0.5)))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white.opacity(0.12), in: Capsule())
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { v in
                    if dragStart == nil { dragStart = progress }
                    progress = max(0, min(1, (dragStart ?? 1) - v.translation.height / sheetH))
                }
                .onEnded { v in
                    dragStart = nil
                    let close = progress < 0.65 || v.predictedEndTranslation.height > 220
                    if close { onClose() }
                    else { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { progress = 1 } }
                }
        )
    }

    private var viewerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if loading {
                    ProgressView().tint(.white).padding(.top, 44).frame(maxWidth: .infinity)
                } else if filtered.isEmpty {
                    ContentUnavailableView("No views yet", systemImage: "eye",
                        description: Text("When people view this story, they'll show up here."))
                        .padding(.top, 40)
                } else {
                    ForEach(filtered) { v in
                        viewerRow(v)
                        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 74)
                    }
                }
            }
            .padding(.bottom, 30)
        }
    }

    private func tabPill(_ title: String, _ tag: Int) -> some View {
        let sel = segment == tag
        return Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(sel ? .white : .white.opacity(0.5))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(sel ? Color.white.opacity(0.14) : .clear, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { segment = tag } }
    }

    private var doubleCheck: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark"); Image(systemName: "checkmark").offset(x: 4)
        }
        .font(.system(size: 9, weight: .bold))
    }

    private func viewerRow(_ v: StoryViewerInfo) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: v.name, photoUrl: v.photoUrl, size: 46)
                .overlay(alignment: .bottomTrailing) {
                    if let r = v.reaction, !r.isEmpty {
                        Text(r).font(.system(size: 11))
                            .frame(width: 19, height: 19)
                            .background(Circle().fill(Color(.systemRed)))
                            .overlay(Circle().stroke(Color(white: 0.10), lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                HStack(spacing: 5) { doubleCheck; Text(dateFmt(v.viewedAt)) }
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Menu {
                Button { } label: { Label("Send message", systemImage: "message") }
                Button { } label: { Label("View profile", systemImage: "person.crop.circle") }
            } label: {
                Image(systemName: "ellipsis").font(.body).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 38, height: 38).contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func dateFmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd/MM/yy 'at' h:mm a"; return f.string(from: d)
    }

    private func load() async {
        let id = activeStoryId
        guard !id.isEmpty else { loading = false; return }
        if viewers.isEmpty { loading = true }
        let v = await StoriesService.shared.fetchViewers(storyId: id)
        if id == activeStoryId { viewers = v; loading = false }
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
