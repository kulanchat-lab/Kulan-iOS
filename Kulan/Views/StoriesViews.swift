import SwiftUI
import PhotosUI
import Photos
import UIKit

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
    var meName: String
    var mePhoto: String?
    var onCompose: () -> Void
    var onOpen: (StoryGroup) -> Void
    var onMessage: (StoryGroup) -> Void = { _ in }
    var onProfile: (StoryGroup) -> Void = { _ in }
    var onOpenAnon: (StoryGroup) -> Void = { _ in }
    @State private var prefsTick = 0   // re-render after hide/notify toggles
    @State private var menuStory: StoryGroup?   // per-card long-press action sheet target

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
                        // Per-card long-press -> native action sheet. A .contextMenu inside a List
                        // cell lifts the WHOLE bar; an action sheet targets just this story reliably.
                        .onLongPressGesture(minimumDuration: 0.4) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            menuStory = g
                        }
                }
            }
            .padding(.horizontal, storyHPad)
            .padding(.vertical, 10)
        }
        .task { await repo.load() }
        .confirmationDialog(menuStory?.name ?? "Story",
                            isPresented: Binding(get: { menuStory != nil }, set: { if !$0 { menuStory = nil } }),
                            titleVisibility: .visible, presenting: menuStory) { g in
            Button("Send Message") { onMessage(g) }
            Button("Open Profile") { onProfile(g) }
            Button(StoryPrefs.isNotifying(g.authorUid) ? "Stop Notifying" : "Notify About Stories") {
                StoryPrefs.toggleNotify(g.authorUid); prefsTick += 1
            }
            Button("View Anonymously") { onOpenAnon(g) }
            Button("Hide Stories", role: .destructive) { StoryPrefs.toggleHidden(g.authorUid); prefsTick += 1 }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var myCard: some View {
        card(cover: repo.mine?.stories.last?.mediaUrl ?? mePhoto,
             name: "My Story", avatar: mePhoto,
             unseen: repo.mine?.hasUnseen ?? false, onBadge: onCompose) {
            if let m = repo.mine { onOpen(m) } else { onCompose() }
        }
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
struct StoryViewer: View {
    let groups: [StoryGroup]
    var anonymous: Bool
    var onClose: () -> Void

    // Single-group entry (e.g. My Story) — no cross-person swipe.
    init(group: StoryGroup, anonymous: Bool = false, onClose: @escaping () -> Void) {
        self.init(groups: [group], startIndex: 0, anonymous: anonymous, onClose: onClose)
    }
    // Full entry: swipe/advance between people across the ordered list.
    init(groups: [StoryGroup], startIndex: Int = 0, anonymous: Bool = false, onClose: @escaping () -> Void) {
        self.groups = groups
        self.anonymous = anonymous
        self.onClose = onClose
        self._groupIndex = State(initialValue: max(0, min(startIndex, max(0, groups.count - 1))))
    }

    // The person whose stories are currently showing.
    private var group: StoryGroup { groups[min(groupIndex, max(0, groups.count - 1))] }

    @State private var groupIndex: Int
    @State private var index = 0
    @State private var progress = 0.0
    @State private var closing = false
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var paused = false
    @State private var menuOpen = false        // "…" action sheet open -> pause the story
    @State private var dragDown: CGFloat = 0   // interactive swipe-down-to-dismiss
    @State private var viewed = Set<String>()
    @State private var showSent = false
    @State private var toastText = "Sent"
    @State private var toastTask: Task<Void, Never>?
    @State private var keyboardHeight: CGFloat = 0
    private let quickEmojis = ["❤️", "😂", "😮", "😢", "👏", "🔥"]
    private let ticker = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    private let perStory = 5.0

    private var story: Story? { group.stories.indices.contains(index) ? group.stories[index] : nil }

    // Swipe-down transform (typed to avoid CGFloat/Double inference ambiguity).
    private var dismissScale: CGFloat { 1 - min(dragDown, 400) / 2400 }
    private var dismissOpacity: Double { Double(1 - min(dragDown, 400) / 800) }

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom

            ZStack {
                Color.black.ignoresSafeArea()

                if let s = story {
                    StoryImage(url: s.mediaUrl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .ignoresSafeArea()
                }

                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity)
                        .onTapGesture { back() }
                        .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 40, perform: {},
                                            onPressingChanged: { paused = $0 })
                    Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity)
                        .onTapGesture { next() }
                        .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 40, perform: {},
                                            onPressingChanged: { paused = $0 })
                }

                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        ForEach(group.stories.indices, id: \.self) { i in
                            GeometryReader { bar in
                                Capsule().fill(.white.opacity(0.3))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(.white)
                                            .frame(width: bar.size.width * fill(i))
                                            .animation(.linear(duration: 0.02), value: progress)
                                    }
                            }
                            .frame(height: 2.5)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, safeTop + 6)

                    HStack(spacing: 10) {
                        AvatarView(name: group.name, photoUrl: group.photoUrl, size: 36)
                        HStack(spacing: 5) {
                            Text(group.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            if let s = story {
                                Text("·").foregroundStyle(.white.opacity(0.7))
                                Text(timeAgo(s.createdAt))
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        Spacer()
                        HStack(spacing: 16) {
                            Button { menuOpen = true } label: {   // pauses the story while open
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                    Spacer()

                    if let s = story, !group.isMine, s.allowsReplies {
                        VStack(spacing: 10) {
                            HStack(spacing: 0) {
                                ForEach(quickEmojis, id: \.self) { e in
                                    Button {
                                        sendToAuthor(s, e)
                                    } label: {
                                        Text(e).font(.system(size: 32))
                                            .frame(maxWidth: .infinity)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)

                            HStack(spacing: 16) {
                                HStack {
                                    TextField("Send message…", text: $replyText)
                                        .focused($replyFocused)
                                        .foregroundStyle(.white)
                                        .tint(.white)
                                        .textFieldStyle(.plain)
                                        .submitLabel(.send)
                                        .onSubmit {
                                            let t = replyText.trimmingCharacters(in: .whitespaces)
                                            guard !t.isEmpty else { return }
                                            replyText = ""; replyFocused = false
                                            sendToAuthor(s, t)
                                        }
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 46)
                                .background(Capsule().fill(Color.black.opacity(0.25)))
                                .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 0.8))

                                Button {
                                    sendToAuthor(s, "❤️")
                                } label: {
                                    Image(systemName: "heart")
                                        .font(.system(size: 24))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    let t = replyText.trimmingCharacters(in: .whitespaces)
                                    guard !t.isEmpty else { return }
                                    replyText = ""; replyFocused = false
                                    sendToAuthor(s, t)
                                } label: {
                                    Image(systemName: "paperplane")
                                        .font(.system(size: 24))
                                        .foregroundStyle(replyText.trimmingCharacters(in: .whitespaces).isEmpty
                                                         ? .white.opacity(0.4) : .white)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            .padding(.horizontal, 12)
                        }
                        .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 8 : safeBottom + 12)
                        .animation(.easeOut(duration: 0.25), value: keyboardHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if showSent {
                    Text(toastText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.black.opacity(0.65), in: Capsule())
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSent)
            // Interactive swipe-down-to-dismiss: the card follows the finger, shrinks +
            // rounds + fades, then dismisses past a threshold or springs back.
            .scaleEffect(dismissScale, anchor: .center)
            .offset(y: dragDown)
            .cornerRadius(dragDown > 0 ? 24 : 0)
            .opacity(dismissOpacity)
        }
        .background(Color.black.ignoresSafeArea())   // pinned backdrop behind the sliding card
        .ignoresSafeArea()
        .onReceive(ticker) { _ in tick() }
        .confirmationDialog("", isPresented: $menuOpen, titleVisibility: .hidden) {
            Button("Save to Gallery") { saveToGallery() }
            if group.isMine {
                Button("Delete", role: .destructive) { deleteCurrentStory() }
            } else {
                Button(StoryPrefs.isNotifying(group.authorUid) ? "Stop Notifying" : "Notify About Stories") {
                    StoryPrefs.toggleNotify(group.authorUid)
                }
                Button("Hide Stories", role: .destructive) { StoryPrefs.toggleHidden(group.authorUid); onClose() }
                Button("Report", role: .destructive) { reportStory() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: story?.id) {   // keyed by story id so it fires across people too
            guard !anonymous, let s = story, !viewed.contains(s.id) else { return }
            viewed.insert(s.id); await StoriesService.shared.markViewed(s)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in
                    if replyFocused { return }
                    // Only drive the dismiss transform for downward-dominant drags; leave
                    // horizontal drags for person-to-person swiping (resolved on release).
                    if v.translation.height > abs(v.translation.width) {
                        dragDown = max(0, v.translation.height)   // never sticks if the finger goes back up
                        if dragDown > 0 { paused = true }
                    }
                }
                .onEnded { v in
                    if replyFocused { replyFocused = false; return }
                    paused = false
                    let dy = v.translation.height, dx = v.translation.width
                    // Horizontal swipe → jump to the next/previous person's stories.
                    if abs(dx) > abs(dy), abs(dx) > 60 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { dragDown = 0 }
                        if dx < 0 { nextGroup() } else { prevGroup() }
                        return
                    }
                    // Require real vertical travel before honouring the velocity branch, so a
                    // quick horizontal/diagonal flick can't accidentally dismiss.
                    if dy > 120 || (dy > 60 && v.predictedEndTranslation.height > 320) {
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { dragDown = 0 }
                    }
                }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            if let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = max(0, UIScreen.main.bounds.height - f.origin.y)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
    }

    private func fill(_ i: Int) -> Double { i < index ? 1 : (i == index ? progress : 0) }

    private func tick() {
        guard !closing, !replyFocused, !paused, !menuOpen, scenePhase == .active, story != nil else { return }
        progress = min(progress + 0.02 / perStory, 1)
        if progress >= 1 { next() }
    }

    private func next() {
        if index < group.stories.count - 1 { index += 1; progress = 0 }
        else { nextGroup() }   // end of this person -> advance to the next person
    }

    private func back() {
        if index > 0 { index -= 1; progress = 0 }
        else if groupIndex > 0 {
            groupIndex -= 1
            index = max(0, group.stories.count - 1)   // land on the previous person's last story
            progress = 0
        } else { progress = 0 }
    }

    // Advance to the next person's stories; close at the very end of the list.
    private func nextGroup() {
        if groupIndex < groups.count - 1 {
            groupIndex += 1; index = 0; progress = 0
        } else {
            closing = true; onClose()
        }
    }

    // Jump to the previous person's first story (horizontal swipe-right).
    private func prevGroup() {
        guard groupIndex > 0 else { progress = 0; return }
        groupIndex -= 1; index = 0; progress = 0
    }

    private func toast(_ text: String) {
        toastTask?.cancel()
        toastText = text; showSent = true
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            showSent = false
        }
    }

    private func saveToGallery() {
        guard let s = story, let img = DiskImageCache.shared.memoryImage(s.mediaUrl) else {
            toast("Save failed"); return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                guard status == .authorized || status == .limited else { toast("Photo access denied"); return }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: img)
                } completionHandler: { ok, _ in
                    Task { @MainActor in toast(ok ? "Saved" : "Save failed") }
                }
            }
        }
    }

    private func reportStory() {
        guard let s = story else { return }
        Task { await StoriesService.shared.reportStory(s); await MainActor.run { toast("Reported") } }
    }

    private func deleteCurrentStory() {
        guard let s = story else { return }
        Task { await StoriesService.shared.deleteStory(s.id) }
        // `group` is immutable, so we can't safely keep navigating the now-stale array
        // (the deleted story would reappear on swipe-back). Close + let repo.load() refresh.
        onClose()
    }

    private func sendToAuthor(_ s: Story, _ text: String) {
        guard !text.isEmpty, let me = AuthService.shared.uid, me != s.authorUid else { return }
        toast("Sent")
        let cid = [me, s.authorUid].sorted().joined(separator: "_")
        Task { try? await ChatService.sendText(cid: cid, text: text) }
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
