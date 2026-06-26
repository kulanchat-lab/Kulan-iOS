import SwiftUI
import PhotosUI
import UIKit

// Horizontal Stories row for the top of the Chats screen: "My Status" cell (tap to add
// or view your own) + friends' rings (unseen = accent ring, seen = grey). Loads on appear.
struct StoriesRow: View {
    @State private var repo = StoriesRepository.shared
    var meName: String
    var mePhoto: String?
    var onCompose: () -> Void
    var onOpen: (StoryGroup) -> Void

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
                ForEach(repo.others) { g in
                    card(cover: g.stories.last?.mediaUrl,
                         name: g.name.isEmpty ? "User" : g.name,
                         avatar: g.photoUrl, unseen: g.hasUnseen) { onOpen(g) }
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
        if let cover, let url = URL(string: cover) {
            AsyncImage(url: url) { p in
                if let img = p.image { img.resizable().scaledToFill() }
                else { Color.secondary.opacity(0.25) }
            }
        } else {
            ZStack {
                Color.secondary.opacity(0.2)
                AvatarView(name: name, photoUrl: avatar, size: cardW * 0.62)
            }
        }
    }

    func reload() { Task { await repo.load() } }
}

// Full-screen story viewer: top progress bars, tap-right = next / tap-left = back,
// auto-advance, swipe-down to close. Marks each shown story viewed.
struct StoryViewer: View {
    let group: StoryGroup
    var onClose: () -> Void

    @State private var index = 0
    @State private var progress = 0.0
    @State private var closing = false
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool
    private let ticker = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    private let perStory = 5.0   // seconds per photo

    private var story: Story? { group.stories.indices.contains(index) ? group.stories[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let s = story {
                AsyncImage(url: URL(string: s.mediaUrl)) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()
            }

            // Tap zones: left third = back, right two-thirds = next.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).onTapGesture { back() }
                Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).onTapGesture { next() }
                    .frame(maxWidth: .infinity)
            }

            VStack {
                HStack(spacing: 4) {
                    ForEach(group.stories.indices, id: \.self) { i in
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.3))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white)
                                        .frame(width: geo.size.width * fill(i))
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
                    if group.isMine {
                        Button { deleteCurrentStory() } label: {
                            Image(systemName: "trash").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        }
                        .padding(.trailing, 6)
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 8)
                Spacer()
                // Reply bar (Signal stories logic) — only on someone else's story that allows replies.
                if let s = story, !group.isMine, s.allowsReplies {
                    replyBar(s)
                }
            }
        }
        .onReceive(ticker) { _ in tick() }
        .task(id: index) { if let s = story { await StoriesService.shared.markViewed(s) } }
        .gesture(DragGesture().onEnded { v in if v.translation.height > 80 { onClose() } })
    }

    private func fill(_ i: Int) -> Double { i < index ? 1 : (i == index ? progress : 0) }

    private func tick() {
        guard !closing, !replyFocused, story != nil else { return }   // also pause while typing a reply
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
    @State private var item: PhotosPickerItem?
    @State private var data: Data?
    @State private var posting = false
    @State private var showCamera = false
    var onPosted: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let data, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFit()
                        .frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Button { Task { await post() } } label: {
                        if posting { ProgressView() }
                        else { Text("Share to My Status").fontWeight(.semibold).frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(posting)
                } else {
                    Spacer()
                    Button { showCamera = true } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    PhotosPicker(selection: $item, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    Text("Photo disappears after 24 hours.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("New Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) } }
            .onChange(of: item) { _, it in
                Task { if let it { data = try? await it.loadTransferable(type: Data.self) } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { captured in data = captured }.ignoresSafeArea()
            }
        }
    }

    private func post() async {
        guard let data else { return }
        posting = true
        try? await StoriesService.shared.postStory(image: data)
        posting = false
        onPosted()
        dismiss()
    }
}
