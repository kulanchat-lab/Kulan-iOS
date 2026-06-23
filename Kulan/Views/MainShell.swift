import SwiftUI

// Native TabView keeps both tabs permanently mounted -> the header avatar never
// unmounts/blinks on tab switch (the RN bug, solved structurally).
struct MainShell: View {
    var onSignOut: () -> Void
    private var call: CallService { CallService.shared }
    var body: some View {
        TabView {
            ChatsView(onSignOut: onSignOut)
                .tabItem { Label("Chats", systemImage: "bubble.fill") }
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
    @State private var pendingMute: Conversation?
    @State private var search = ""
    // Multi-select edit mode (Telegram-style).
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showArchived = false
    @State private var showDeleteSelected = false

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }

    private var visible: [Conversation] {
        repo.conversations
            .filter { !$0.isCleared(me) && !$0.isArchived(me) }
            .sorted { a, b in
                if a.isPinned(me) != b.isPinned(me) { return a.isPinned(me) }
                // Both pinned: manual order (higher rank = higher in list).
                if a.isPinned(me) && b.isPinned(me) {
                    if a.pinRank(me) != b.pinRank(me) { return a.pinRank(me) > b.pinRank(me) }
                    return a.updatedAtMillis > b.updatedAtMillis
                }
                return a.updatedAtMillis > b.updatedAtMillis   // both unpinned: recency
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
    // Avatar dropdown menu: Select Chats / Settings / Archive (Telegram-style).
    private var avatarMenu: some View {
        Menu {
            Button { selecting = true } label: { Label("Select Chats", systemImage: "checkmark.circle") }
            Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            Button { showArchived = true } label: { Label("Archive", systemImage: "archivebox") }
        } label: {
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 40)
        }
    }
    private var composeButton: some View {
        Button { showNew = true } label: {
            Image(systemName: "square.and.pencil").font(.system(size: 18))
        }
        .tint(.primary)   // glass circle (default), black glyph
    }

    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { exitSelect() } }
            ToolbarItem(placement: .principal) {
                Text(selection.isEmpty ? "Select Chats" : "\(selection.count) Selected").font(.headline)
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Select All") { selectAll() } }
        } else if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { avatarMenu }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { composeButton }
        } else {
            ToolbarItem(placement: .topBarLeading) { avatarMenu }
            ToolbarItem(placement: .topBarTrailing) { composeButton }
        }
    }

    // Bottom action bar shown in edit mode (replaces the tab bar).
    // Three floating glass buttons: Archive ○ · "Read All" capsule · Delete ○ (red).
    private var selectionBar: some View {
        HStack {
            Button { archiveSelected() } label: {
                Image(systemName: "archivebox").font(.system(size: 20))
                    .frame(width: 48, height: 48)
            }
            .liquidGlass(Circle())
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            Spacer()
            Button { markReadSelected() } label: {
                Text("Read All").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22).frame(height: 48)
            }
            .liquidGlass(Capsule())
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            Spacer()
            Button { showDeleteSelected = true } label: {
                Image(systemName: "trash").font(.system(size: 20)).foregroundStyle(.red)
                    .frame(width: 48, height: 48)
            }
            .liquidGlass(Circle())
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .tint(.primary)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .disabled(selection.isEmpty)
        .opacity(selection.isEmpty ? 0.5 : 1)
    }

    // Persist a pinned-chat reorder via fractional indexing (Telegram-style).
    private func reorderPinned(from source: IndexSet, to destination: Int) {
        guard search.isEmpty else { return }            // indices map to a subset while searching
        let rows = filtered
        guard let from = source.first, rows.indices.contains(from) else { return }
        let moved = rows[from]
        guard moved.isPinned(me) else { return }

        let pinnedCount = rows.prefix { $0.isPinned(me) }.count
        guard pinnedCount > 1 else { return }

        // Clamp into the pinned block so a pin can't be dropped among unpinned chats.
        let dest = min(max(destination, 0), pinnedCount)
        var pinned = Array(rows[0..<pinnedCount])
        pinned.move(fromOffsets: IndexSet(integer: from), toOffset: dest)
        guard let pos = pinned.firstIndex(where: { $0.id == moved.id }) else { return }

        let above = pos > 0 ? pinned[pos - 1].pinRank(me) : nil          // higher in list = bigger rank
        let below = pos < pinned.count - 1 ? pinned[pos + 1].pinRank(me) : nil
        let step = 1_000_000.0
        let newRank: Double
        switch (above, below) {
        case let (a?, b?): newRank = (a + b) / 2
        case let (a?, nil): newRank = a - step
        case let (nil, b?): newRank = b + step
        case (nil, nil): return
        }
        Task { await ChatService.setPinOrder(moved.id, newRank) }
    }

    private func exitSelect() { selecting = false; selection = [] }
    private func selectAll() { selection = Set(filtered.map { $0.id }) }
    private func archiveSelected() {
        let ids = selection
        Task { for id in ids { await ChatService.setArchived(id, true) } }
        exitSelect()
    }
    private func markReadSelected() {
        let ids = selection
        Task { for id in ids { await ChatService.resetUnread(id); await ChatService.markRead(id) } }
        exitSelect()
    }
    private func deleteSelected() {
        let ids = selection
        Task { for id in ids { await ChatService.deleteForMe(id) } }
        exitSelect()
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if visible.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap the compose button to start one."))
                } else {
                    List(selection: selecting ? $selection : .constant(Set<String>())) {
                      ForEach(filtered) { conv in
                        NavigationLink(value: ChatTarget(id: conv.id, name: conv.name(for: me),
                                                         photo: conv.photoUrl(for: me))) {
                            ChatRow(conv: conv, me: me, dark: dark)
                        }
                        .tag(conv.id)
                        .listRowSeparator(.hidden)
                        .moveDisabled(!conv.isPinned(me) || !search.isEmpty)   // only pinned drag
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = conv
                            } label: { Label("Delete", systemImage: "trash") }
                            .tint(.red)
                            Button {
                                Task { await ChatService.setArchived(conv.id, true) }
                            } label: { Label("Archive", systemImage: "archivebox") }
                            .tint(.gray)
                            Button { pendingMute = conv } label: { Label("Mute", systemImage: "bell.slash") }
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
                      .onMove { source, destination in
                          reorderPinned(from: source, to: destination)
                      }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(selecting ? .active : .inactive))
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
            .confirmationDialog("Mute \(pendingMute?.name(for: me) ?? "")",
                                isPresented: Binding(get: { pendingMute != nil },
                                                     set: { if !$0 { pendingMute = nil } }),
                                titleVisibility: .visible) {
                if let c = pendingMute {
                    if c.isMuted(me, now: Date().timeIntervalSince1970 * 1000) {
                        Button("Unmute") { Task { await ChatService.setMute(c.id, until: 0) }; pendingMute = nil }
                    }
                    Button("Mute for 1 hour") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(1)) }; pendingMute = nil }
                    Button("Mute for 8 hours") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(8)) }; pendingMute = nil }
                    Button("Mute for 1 week") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(168)) }; pendingMute = nil }
                    Button("Mute Always") { Task { await ChatService.setMute(c.id, until: ChatService.muteUntil(nil)) }; pendingMute = nil }
                }
                Button("Cancel", role: .cancel) { pendingMute = nil }
            }
            .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .sheet(isPresented: $showArchived) { ArchivedChatsView() }
            .confirmationDialog("Delete \(selection.count) chat\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteSelected, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear { repo.start() }
    }
}

// Archived chats (reached from the avatar menu). Swipe to unarchive.
struct ArchivedChatsView: View {
    private var repo = ConversationsRepository.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var me: String { AuthService.shared.uid ?? "" }
    private var archived: [Conversation] {
        repo.conversations.filter { $0.isArchived(me) && !$0.isCleared(me) }
            .sorted { $0.updatedAtMillis > $1.updatedAtMillis }
    }
    var body: some View {
        NavigationStack {
            Group {
                if archived.isEmpty {
                    ContentUnavailableView("No archived chats", systemImage: "archivebox",
                                           description: Text("Chats you archive will show here."))
                } else {
                    List(archived) { conv in
                        ChatRow(conv: conv, me: me, dark: scheme == .dark)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button { Task { await ChatService.setArchived(conv.id, false) } } label: {
                                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                                }.tint(.indigo)
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
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
            AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 48)
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
        .padding(.vertical, 8)   // balanced row height with the 56pt avatar
    }
}
