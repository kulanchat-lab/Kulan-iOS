import SwiftUI

// Native TabView keeps both tabs permanently mounted -> the header avatar never
// unmounts/blinks on tab switch (the RN bug, solved structurally).
struct MainShell: View {
    var onSignOut: () -> Void
    private var call = CallService.shared
    var body: some View {
        TabView {
            ChatsView(onSignOut: onSignOut)
                .tabItem { Label("Chats", systemImage: "bubble.left.fill") }
            CallsView()
                .tabItem { Label("Calls", systemImage: "phone.fill") }
        }
        .onAppear { call.observeIncoming() }
        .fullScreenCover(isPresented: Binding(
            get: { call.state != .idle },
            set: { if !$0 && call.state != .idle { call.hangUp() } }
        )) {
            CallView()
        }
    }
}

struct CallsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Calls coming soon").font(.headline)
            Text("Voice and video will live here.").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct ChatsView: View {
    var onSignOut: () -> Void
    init(onSignOut: @escaping () -> Void = {}) { self.onSignOut = onSignOut }
    private var repo = ConversationsRepository.shared
    private var profile = ProfileStore.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showNew = false
    @State private var showSettings = false
    @State private var path = NavigationPath()
    @State private var pendingDelete: Conversation?
    @State private var search = ""

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }

    private var visible: [Conversation] {
        repo.conversations
            .filter { !$0.isCleared(me) && !$0.isArchived(me) }
            .sorted {
                if $0.isPinned(me) != $1.isPinned(me) { return $0.isPinned(me) }
                return $0.updatedAtMillis > $1.updatedAtMillis
            }
    }

    // Real search: filter the visible chats by contact name.
    private var filtered: [Conversation] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return visible }
        return visible.filter { $0.name(for: me).lowercased().contains(q) }
    }

    // Native nav bar with a crisp circle avatar — glass stripped via the iOS 26
    // opt-out, same as the chat header. Keeps the large "Chats" title + smooth
    // push transitions instead of a hand-rolled bar.
    private var avatarButton: some View {
        Button { showSettings = true } label: {
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 32)
        }
        .buttonStyle(.plain)
    }
    private var composeButton: some View {
        Button { showNew = true } label: {
            Image(systemName: "square.and.pencil").font(.system(size: 18))
        }
        .tint(.primary)   // glass circle (default), black glyph
    }
    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            // Avatar stays a crisp plain circle; compose keeps its glass circle.
            ToolbarItem(placement: .topBarLeading) { avatarButton }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { composeButton }
        } else {
            ToolbarItem(placement: .topBarLeading) { avatarButton }
            ToolbarItem(placement: .topBarTrailing) { composeButton }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if visible.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left",
                                           description: Text("Tap the compose button to start one."))
                } else {
                    List(filtered) { conv in
                        NavigationLink(value: ChatTarget(id: conv.id, name: conv.name(for: me),
                                                         photo: conv.photoUrl(for: me))) {
                            ChatRow(conv: conv, me: me, dark: dark)
                        }
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = conv
                            } label: { Label("Delete", systemImage: "trash") }
                            Button {
                                let now = Date().timeIntervalSince1970 * 1000
                                Task { await ChatService.setMuted(conv.id, !conv.isMuted(me, now: now)) }
                            } label: { Label("Mute", systemImage: "bell.slash") }
                            .tint(.indigo)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) }
                            } label: {
                                Label(conv.isPinned(me) ? "Unpin" : "Pin", systemImage: "pin")
                            }
                            .tint(.orange)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)   // one row: avatar · Chats · compose
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar { homeToolbar }
            // ONE destination type for every chat (list taps AND search results),
            // keyed by cid via .id(...) so each conversation gets a fresh ThreadView
            // identity — a new chat can never inherit the previous chat's @State
            // (repo/cid), which was the cross-routing bug.
            .navigationDestination(for: ChatTarget.self) { t in
                ThreadView(cid: t.id, title: t.name, photoUrl: t.photo)
                    .id(t.id)
            }
            .sheet(isPresented: $showNew) {
                NewChatView { t in
                    // Push behind the sheet, then dismiss — no flash back to the list.
                    path.append(t)
                    showNew = false
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(onSignOut: onSignOut) }
            .confirmationDialog("Delete this chat?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete Chat", role: .destructive) {
                    if let c = pendingDelete { Task { await ChatService.deleteForMe(c.id) } }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("This removes the chat from your list. It comes back if you get a new message.")
            }
        }
        .onAppear { repo.start() }
    }
}

struct ChatRow: View {
    let conv: Conversation
    let me: String
    let dark: Bool

    private var preview: String {
        let decoded = Crypto.shared.decrypt(conv.lastMessageCipher, cid: conv.id)
        return decoded.isEmpty ? "Say hello 👋" : decoded
    }
    private var unread: Int { conv.unread(me) }

    private var timeStr: String {
        let ms = conv.updatedAtMillis
        guard ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated))
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conv.name(for: me))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(timeStr)
                        .font(.caption)
                        .foregroundStyle(unread > 0 ? Theme.accent(dark) : .secondary)
                }
                HStack {
                    Text(preview)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if unread > 0 {
                        Text("\(min(unread, 99))")
                            .font(.caption2.bold()).foregroundColor(Theme.onAccent(dark))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.accent(dark)).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}
