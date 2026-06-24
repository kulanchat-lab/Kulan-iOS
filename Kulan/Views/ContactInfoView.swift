import SwiftUI
import FirebaseAuth
import FirebaseFirestore

// Telegram-style profile screen: hero avatar, quick-action tiles, bio card, and a
// shared-media card. Real where the data exists (name/@handle, mute, block, clear,
// shared media, bio); honest "coming soon" for features not built yet (calls live
// on a separate branch; in-chat search isn't built). No fabricated data — the title
// is the @handle (Kulan has no phone numbers).
struct ContactInfoView: View {
    let cid: String
    let name: String
    let photoUrl: String?

    @State private var handle = ""
    @State private var about = ""
    @State private var muted = false
    @State private var blocked = false
    @State private var loaded = false
    @State private var media: [Message] = []
    @State private var viewerImage: Message?
    @State private var showClear = false
    @State private var showBlock = false
    @State private var showCallSoon = false
    @State private var showSearchSoon = false
    @State private var showAllMedia = false
    @State private var showMuteOptions = false
    @State private var showDisappear = false
    @State private var disappearSeconds = 0
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var cardColor: Color { dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xF2F2F7) }
    private var otherUid: String {
        let me = AuthService.shared.uid ?? ""
        return cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                quickActions
                disappearRow
                if !about.isEmpty { bioCard }
                if !media.isEmpty { mediaCard }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle(handle.isEmpty ? name : "@\(handle)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)   // show nav bar (back + title) below the notch
        .navigationBarBackButtonHidden(false)
        .task {
            await load()
            disappearSeconds = ConversationsRepository.shared.conversations.first(where: { $0.id == cid })?.disappearSeconds ?? 0
        }
        .confirmationDialog("Disappearing Messages", isPresented: $showDisappear, titleVisibility: .visible) {
            Button("Off") { setDisappear(0) }
            Button("1 Day") { setDisappear(86_400) }
            Button("1 Week") { setDisappear(604_800) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New and existing messages auto-delete after the timer. Applies for both of you.")
        }
        .fullScreenCover(item: $viewerImage) { msg in ImageViewerView(message: msg, cid: cid) }
        .sheet(isPresented: $showAllMedia) { SharedMediaGridView(cid: cid, media: media) }
        .alert("Clear your messages?", isPresented: $showClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task { await ChatService.clearMyMessages(cid); media = await ChatService.sharedMedia(cid) }
            }
        } message: {
            Text("This deletes the messages you sent in this chat. It can't be undone.")
        }
        .alert("Block \(name)?", isPresented: $showBlock) {
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                Task { await ChatService.setBlocked(cid, true); blocked = true }
            }
        } message: {
            Text("You won't be able to send messages in this chat until you unblock. \(name) won't be told they were blocked.")
        }
        .alert("Voice calls", isPresented: $showCallSoon) {
            Button("OK", role: .cancel) {}
        } message: { Text("Voice calling is coming soon.") }
        .alert("Search", isPresented: $showSearchSoon) {
            Button("OK", role: .cancel) {}
        } message: { Text("In-chat search is coming soon.") }
        .confirmationDialog("Mute \(name)", isPresented: $showMuteOptions, titleVisibility: .visible) {
            if muted {
                Button("Unmute") { muted = false; Task { await ChatService.setMute(cid, until: 0) } }
            }
            Button("Mute for 1 hour") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(1)) } }
            Button("Mute for 8 hours") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(8)) } }
            Button("Mute for 1 week") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(168)) } }
            Button("Mute Always") { muted = true; Task { await ChatService.setMute(cid, until: ChatService.muteUntil(nil)) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var disappearLabel: String {
        switch disappearSeconds { case 86_400: return "1 day"; case 604_800: return "1 week"; default: return "Off" }
    }
    private func setDisappear(_ s: Int) {
        disappearSeconds = s
        Task { await ChatService.setDisappear(cid, seconds: s) }
    }
    private var disappearRow: some View {
        Button { showDisappear = true } label: {
            HStack {
                Label("Disappearing Messages", systemImage: "timer")
                Spacer()
                Text(disappearLabel).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 6) {
            AvatarView(name: name, photoUrl: photoUrl, size: 88)
            Text(name).font(.title.weight(.bold))
            if !handle.isEmpty {
                Text("@\(handle)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            actionTile("call", "phone.fill") { CallService.shared.startCall(to: otherUid, name: name, photo: photoUrl) }
            actionTile(muted ? "unmute" : "mute", muted ? "bell.fill" : "bell.slash.fill") { showMuteOptions = true }
            actionTile("search", "magnifyingglass") { showSearchSoon = true }
            Menu {
                if blocked {
                    Button { Task { await ChatService.setBlocked(cid, false); blocked = false } } label: {
                        Label("Unblock", systemImage: "hand.raised.slash")
                    }
                } else {
                    Button(role: .destructive) { showBlock = true } label: {
                        Label("Block \(name)", systemImage: "hand.raised")
                    }
                }
                Button(role: .destructive) { showClear = true } label: {
                    Label("Clear my messages", systemImage: "trash")
                }
            } label: { tileLabel("more", "ellipsis") }
                .tint(.primary)
        }
    }

    private func actionTile(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, icon) }.tint(.primary)
    }

    private func tileLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(cardColor, in: Capsule())   // pill tile, icon only
            Text(title).font(.caption).foregroundStyle(.primary)   // label below the tile
        }
    }

    private var bioCard: some View {
        Text(about)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(media.prefix(12)) { m in
                        if let url = m.imageUrl {
                            SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { viewerImage = m }
                        }
                    }
                }
            }
            Button("See All") { showAllMedia = true }
                .font(.subheadline.weight(.medium))
                .tint(.primary)
        }
        .padding(14)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Logic

    private func toggleMute() {
        muted.toggle()
        let v = muted
        Task { await ChatService.setMuted(cid, v) }
    }

    private func load() async {
        if let p = await ProfileStore.shared.fetch(otherUid) { handle = p.handle; about = p.about }
        if let snap = try? await Firestore.firestore().collection("conversations").document(cid).getDocument(),
           let d = snap.data() {
            let me = AuthService.shared.uid ?? ""
            let muteUntil = ((d["mutedBy"] as? [String: Any])?[me] as? NSNumber)?.doubleValue ?? 0
            muted = muteUntil > Date().timeIntervalSince1970 * 1000
            blocked = (d["blockedBy"] as? [String: Any])?[me] as? Bool ?? false
        }
        media = await ChatService.sharedMedia(cid)
        loaded = true
    }
}

// Full shared-media gallery (reached via "See All").
struct SharedMediaGridView: View {
    let cid: String
    let media: [Message]
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: Message?
    private let cols = [GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 3) {
                    ForEach(media) { m in
                        if let url = m.imageUrl {
                            SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                                .frame(height: 116)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .onTapGesture { viewer = m }
                        }
                    }
                }
                .padding(2)
            }
            .navigationTitle("Shared Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $viewer) { ImageViewerView(message: $0, cid: cid) }
        }
    }
}
