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

// Custom per-card story context menu. Native `.contextMenu` can't work here: inside a `List`,
// SwiftUI collapses every per-card menu in one row into ONE menu (the first card's), centered.
// So each card long-presses → this payload → a clear full-screen cover owned by StoriesRow.
private struct StoryMenu: Identifiable {
    let id = UUID()
    let cover: String?          // cover image url (nil/empty → avatar placeholder)
    let name: String
    let avatar: String?
    let items: [StoryMenuItem]
}

private struct StoryMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let destructive: Bool
    let action: () -> Void
}

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
    @State private var storyMenu: StoryMenu?          // custom long-press context menu target
    @State private var pendingAction: (() -> Void)?   // action to run AFTER the cover fully dismisses

    private let storySpacing: CGFloat = 10
    private let storyHPad: CGFloat = 12
    private var cardW: CGFloat {
        (UIScreen.main.bounds.width - storyHPad * 2 - storySpacing * 3) / 4
    }
    private var cardH: CGFloat { cardW * 1.46 }

    // Ordering: UNVIEWED first (original order), then VIEWED — most-recently-viewed first. Re-sorts live
    // (no reload) the instant a story is opened (markSeenLocally sets lastViewedAt) and the cards animate.
    private var orderedOthers: [StoryGroup] {
        let _ = prefsTick   // re-evaluate after hide/seen toggles
        let visible = repo.others.filter { !StoryPrefs.isHidden($0.authorUid) }
        let unviewed = visible.filter { $0.hasUnseen }
        let viewed = visible.filter { !$0.hasUnseen }
            .sorted { ($0.lastViewedAt ?? .distantPast) > ($1.lastViewedAt ?? .distantPast) }
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
                                    onLongPress: { presentMenu($0) },
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
        .fullScreenCover(item: $storyMenu, onDismiss: {
            // Run the picked action only after the cover is fully gone (avoids nested-cover conflicts
            // when the action itself presents the story viewer).
            let a = pendingAction; pendingAction = nil; a?()
        }) { menu in
            StoryContextMenuOverlay(menu: menu, cardW: cardW, cardH: cardH) { action in
                dismissMenu(action)   // action == nil for a backdrop tap
            }
            .presentationBackground(.clear)   // see-through cover → escapes the List row's clipping
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
                // Custom long-press (native .contextMenu can't work per-card inside the List).
                // simultaneousGesture (not .onLongPressGesture) so the press runs ALONGSIDE the card's Button —
                // otherwise the Button wins the exclusive gesture and the long-press never fires.
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    presentMenu(StoryMenu(
                        cover: repo.mine?.stories.last?.mediaUrl ?? mePhoto,
                        name: "My Story",
                        avatar: mePhoto,
                        items: [
                            StoryMenuItem(title: "Add Story", systemImage: "plus",
                                          destructive: false, action: onCompose),
                            StoryMenuItem(title: "Posted Stories", systemImage: "circle.dashed",
                                          destructive: false) {
                                if let m = repo.mine, !m.stories.isEmpty { onOpen(m) }
                            }
                        ]))
                })
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

    // Present/dismiss the custom menu WITHOUT the cover's default bottom-slide, so the overlay's own
    // spring+scale is the only animation (matches the iOS context-menu feel).
    private func presentMenu(_ m: StoryMenu) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { storyMenu = m }
    }
    private func dismissMenu(_ action: (() -> Void)?) {
        pendingAction = action
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { storyMenu = nil }   // onDismiss: fires pendingAction after it's gone
    }
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
    let onLongPress: (StoryMenu) -> Void   // signals up to StoriesRow (this struct is separate)
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
        // simultaneousGesture so the long-press coexists with the card's Button (else the Button eats it).
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress(StoryMenu(
                cover: cover, name: name, avatar: avatar,
                items: [
                    StoryMenuItem(title: "Send Message", systemImage: "message",
                                  destructive: false, action: onMessage),
                    StoryMenuItem(title: "Open Profile", systemImage: "person.crop.circle",
                                  destructive: false, action: onProfile),
                    StoryMenuItem(title: "Hide Stories", systemImage: "archivebox",
                                  destructive: true, action: onHide)
                ]))
        })
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

// Custom iOS-context-menu-style overlay for a story card long-press. Lives in a clear full-screen
// cover owned by StoriesRow so it escapes the chat List's row clipping and covers the whole screen.
private struct StoryContextMenuOverlay: View {
    let menu: StoryMenu
    let cardW: CGFloat
    let cardH: CGFloat
    let onDismiss: (_ action: (() -> Void)?) -> Void   // nil action = cancel

    @State private var shown = false          // drives the spring-in / animate-out
    @State private var dragY: CGFloat = 0      // swipe-down to dismiss

    private var previewW: CGFloat { cardW * 1.4 }
    private var previewH: CGFloat { previewW * 1.46 }   // same aspect as the cards
    private let menuW: CGFloat = 230

    var body: some View {
        ZStack {
            // Dimmed + blurred backdrop. Tap anywhere to dismiss with no action.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { close(nil) }

            VStack(spacing: 14) {
                preview
                    .frame(width: previewW, height: previewH)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 22, y: 12)
                menuCard
            }
            .scaleEffect(shown ? 1 : 0.86)
            .opacity(shown ? 1 : 0)
            .offset(y: dragY)
            .padding(.bottom, 40)
        }
        // Swipe-down anywhere on the floating content dismisses (buttons still tap: they win on a tap).
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in dragY = max(0, v.translation.height) }
                .onEnded { v in
                    if v.translation.height > 90 { close(nil) }
                    else { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dragY = 0 } }
                }
        )
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) { shown = true }
        }
    }

    @ViewBuilder private var preview: some View {
        if let cover = menu.cover, !cover.isEmpty {
            StoryImage(url: cover)
        } else {
            ZStack {
                Color.secondary.opacity(0.2)
                AvatarView(name: menu.name, photoUrl: menu.avatar, size: previewW * 0.5)
            }
        }
    }

    private var menuCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(menu.items.enumerated()), id: \.element.id) { idx, item in
                Button { close(item.action) } label: {
                    HStack(spacing: 12) {
                        Text(item.title)
                            .font(.system(size: 17))
                            .foregroundStyle(item.destructive ? Color.red : Color.primary)
                        Spacer(minLength: 8)
                        Image(systemName: item.systemImage)
                            .font(.system(size: 17))
                            .foregroundStyle(item.destructive ? Color.red : Color.primary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if idx < menu.items.count - 1 {
                    Divider().overlay(Color.primary.opacity(0.08))
                }
            }
        }
        .frame(width: menuW)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    private func close(_ action: (() -> Void)?) {
        withAnimation(.easeOut(duration: 0.18)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.19) { onDismiss(action) }
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
    private var myStories: [Story] { groups.first { $0.isMine }?.stories ?? [] }
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
        StoryView(
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
            onUserChanged: { uid in currentBucketUid = uid; markSeen(authorUid: uid); loadBarViewers() },
            onItemSeen: { id in currentStoryId = id; StoryPrefs.markStorySeen(id); markSeenItem(id); loadBarViewers() },
            onDrag: { d in dragDown = d },   // fade my overlays out as the card is pulled down
            showMore: true, // "…" is a native dropdown menu in the header; its buttons post notifications
            onSwipeUp: { if currentIsMine { showViewers = true } }  // Telegram: swipe up opens your viewers
        )
        .ignoresSafeArea()
        // My own story: Telegram owner bar (Views + reactions + delete) instead of a reply bar.
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
                            if v.translation.height < -30 { showViewers = true }
                        }
                    )
            }
        }
        // Viewers (image 2): carousel of my posted stories on top (centre large, neighbours peek, view/❤️
        // counts) + search + viewer list below. Swiping the carousel re-centres a story and its viewer list.
        .sheet(isPresented: $showViewers) {
            StoryViewersSheet(stories: myStories, selectedId: currentStoryId)
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
            let sheetH = geo.size.height * 0.60     // sheet occupies the bottom ~60%
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

struct StoryViewersSheet: View {
    let stories: [Story]
    let selectedId: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String = ""
    @State private var scrolledID: String?      // carousel-centered card → drives which story's viewers show
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
        v.sort { $0.viewedAt > $1.viewedAt }     // most recent viewer first
        return v
    }

    var body: some View {
        // ONE scrolling surface (Telegram): carousel of your story cards on top, then the tabs + search
        // PINNED, then the viewer list. Scrolling the carousel up reveals the full list. Full height +
        // opaque background so the live story underneath never shows through — that double-image was the
        // "owner appears twice" bug, NOT the carousel itself.
        // Telegram (image_9): top is a horizontal carousel of ALL my posted stories (centered card large,
        // others flank smaller, with view/❤️ counts) → PINNED All Viewers/Contacts + Search → viewer list.
        // Full-height, opaque black so the live story underneath never shows (no duplicate).
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                storyCarousel
                Section {
                    if loading {
                        ProgressView().padding(.top, 40).frame(maxWidth: .infinity)
                    } else if viewers.isEmpty {
                        ContentUnavailableView("No views yet", systemImage: "eye",
                                               description: Text("When people view this story, they'll show up here."))
                            .padding(.top, 30)
                    } else {
                        ForEach(viewers) { v in
                            viewerRow(v)
                            Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 72)
                        }
                    }
                } header: { listControls }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(.black.opacity(0.4), in: Circle())
            }
            .padding(.trailing, 14).padding(.top, 10)
        }
        .presentationDetents([.large])
        .presentationBackground(.black)
        .onChange(of: scrolledID) { _, v in if let v { selected = v } }   // centered card → its viewers
        .task { await loadAll() }
    }

    // Horizontal carousel: centred card LARGE, neighbours peek + shrink. Native scroll = continuous
    // finger-follow + snap-to-centre + no bounce. The centred story's count shows BIG below (reference #595).
    private var storyCarousel: some View {
        let active = byStory[selected] ?? []
        let activeReacts = active.filter { !($0.reaction ?? "").isEmpty }.count
        return VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(stories, id: \.id) { s in storyCard(s) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, max(16, (UIScreen.main.bounds.width - 184) / 2))   // centre the focused card
                .padding(.top, 10)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledID)
            .frame(height: 300)
            // The active (centre) card's count, big + centred under the carousel.
            countRow(views: active.count, likes: activeReacts, big: true)
                .padding(.bottom, 6)
        }
    }

    private func storyCard(_ s: Story) -> some View {
        let vs = byStory[s.id] ?? []
        let reacts = vs.filter { !($0.reaction ?? "").isEmpty }.count
        let w: CGFloat = 184, h: CGFloat = 300
        return StoryImage(url: s.mediaUrl)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))   // EXACT match to the story cards (24)
            .overlay(alignment: .bottom) {
                // Side cards show a small count; the CENTRED card hides it (the big count is shown below).
                countRow(views: vs.count, likes: reacts, big: false)
                    .padding(.bottom, 10)
                    .scrollTransition(.interactive) { c, phase in
                        c.opacity(phase.isIdentity ? 0 : 1)
                    }
            }
            // Scale driven by the SCROLL itself (not a GeometryReader) — centre card full size, neighbours
            // shrink, interpolated smoothly during the drag. viewAligned snaps to centre on release, so there's
            // no glitch / duplicate / stuck-between-positions bug.
            .scrollTransition(.interactive) { content, phase in
                content
                    .scaleEffect(phase.isIdentity ? 1.0 : 0.76)
                    .opacity(phase.isIdentity ? 1.0 : 0.9)
            }
            .id(s.id)
            .onTapGesture { withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { scrolledID = s.id } }
    }

    // Eye + views + heart + likes, white over a soft shadow (reference). `big` = the centred-card count below.
    private func countRow(views: Int, likes: Int, big: Bool) -> some View {
        HStack(spacing: big ? 7 : 5) {
            Image(systemName: "eye.fill")
            Text(compactCount(views))
            if likes > 0 {
                Image(systemName: "heart.fill").foregroundStyle(.red).padding(.leading, 4)
                Text(compactCount(likes))
            }
        }
        .font(big ? .subheadline.weight(.bold) : .caption2.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private func compactCount(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K") }
        return "\(n)"
    }

    // Pinned controls: All Viewers / Contacts + Search. Opaque bg so rows don't show through when pinned.
    private var listControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {   // Telegram pill tabs (centered), not a segmented control
                Spacer()
                tabPill("All Viewers", 0)
                tabPill("Contacts", 1)
                Spacer()
            }
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("", text: $search, prompt: Text("Search").foregroundColor(.white.opacity(0.5)))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.white.opacity(0.12), in: Capsule())
            .padding(.horizontal, 16)
        }
        .padding(.top, 8).padding(.bottom, 10)
        .background(Color.black)
    }


    // Telegram pill tab: filled capsule when selected, dimmed plain text otherwise.
    private func tabPill(_ title: String, _ tag: Int) -> some View {
        let selected = segment == tag
        return Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? .white : .white.opacity(0.5))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(selected ? Color.white.opacity(0.14) : .clear, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { segment = tag } }
    }

    // Telegram's grey "seen" read-check shown before each viewer's timestamp (two offset checkmarks).
    private var doubleCheck: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark").offset(x: 4)
        }
        .font(.system(size: 9, weight: .bold))
    }

    private func viewerRow(_ v: StoryViewerInfo) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: v.name, photoUrl: v.photoUrl, size: 46)
                .overlay(alignment: .bottomTrailing) {
                    // Reaction shown as a small badge on the avatar (reference), not a big emoji on the right.
                    if let r = v.reaction, !r.isEmpty {
                        Text(r).font(.system(size: 11))
                            .frame(width: 19, height: 19)
                            .background(Circle().fill(Color(.systemRed)))
                            .overlay(Circle().stroke(Color.black, lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(.body.weight(.semibold)).foregroundStyle(.white)
                HStack(spacing: 5) {
                    doubleCheck                                    // grey read-check, like Telegram
                    Text(dateFmt(v.viewedAt))
                }
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
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy 'at' h:mm a"
        return f.string(from: d)
    }

    private func loadAll() async {
        selected = selectedId.isEmpty ? (stories.last?.id ?? "") : selectedId
        scrolledID = selected   // open the carousel centered on the story you swiped up from
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
