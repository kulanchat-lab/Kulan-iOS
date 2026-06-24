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
        // Call UI is mounted at the root (CallContainer in RootView) so it survives all
        // navigation. Here we only start listening for incoming calls.
        .onAppear { call.observeIncoming() }
    }
}

// Native Phone-app-style call history (mockup IMG_4467): All / Missed segmented filter,
// search, rows with avatar, name (red if missed), direction, time, and an info button.
// Tap a row to call back; (i) opens the contact. Indigo brand kept.
struct CallsView: View {
    @State private var repo = CallsRepository.shared
    @State private var filter = 0            // 0 = All, 1 = Missed
    @State private var query = ""
    @State private var infoTarget: CallEntry?
    @State private var showNew = false

    private var shown: [CallEntry] {
        var list = repo.calls
        if filter == 1 { list = list.filter { $0.missed } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) } }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if repo.calls.isEmpty {
                    ContentUnavailableView("No Calls Yet", systemImage: "phone",
                                           description: Text("Your call history will appear here."))
                } else {
                    List {
                        ForEach(shown) { call in
                            CallHistoryRow(call: call, onInfo: { infoTarget = call })
                                .listRowSeparator(.visible)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    CallService.shared.startCall(to: call.otherUid, name: call.name, photo: call.photoUrl)
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Calls")
            .searchable(text: $query, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $filter) {
                        Text("All").tag(0)
                        Text("Missed").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "phone.badge.plus") }
                }
            }
            .task { await repo.load() }
            .refreshable { await repo.load() }
            .sheet(item: $infoTarget) { c in
                NavigationStack { ContactInfoView(cid: c.cid, name: c.name, photoUrl: c.photoUrl) }
            }
            .sheet(isPresented: $showNew) { NewCallView() }
        }
    }
}

struct CallHistoryRow: View {
    let call: CallEntry
    var onInfo: () -> Void

    private var directionIcon: String { call.mine ? "arrow.up.right" : "arrow.down.left" }
    private var directionText: String { call.missed ? "Missed" : (call.mine ? "Outgoing" : "Incoming") }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: call.name, photoUrl: call.photoUrl, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(call.missed ? Color.red : Color.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: directionIcon).font(.system(size: 11, weight: .semibold))
                    Text(directionText).font(.system(size: 14))
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(timeLabel(call.date)).font(.system(size: 14)).foregroundStyle(.secondary)
            Button(action: onInfo) {
                Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func timeLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

// "New call" picker (mockup IMG_4490): search + your people, each with a call button.
// Voice-only for now (no fake video buttons); reuses existing conversations.
struct NewCallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    private var me: String { AuthService.shared.uid ?? "" }

    private var people: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = repo.conversations.filter { !$0.otherUid(me).isEmpty }
        return (q.isEmpty ? list : list.filter { $0.name(for: me).lowercased().contains(q) })
            .sorted { $0.name(for: me).lowercased() < $1.name(for: me).lowercased() }
    }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    ContentUnavailableView("No contacts", systemImage: "person.crop.circle",
                                           description: Text("Start a chat first, then you can call them."))
                } else {
                    List {
                        ForEach(people) { c in
                            HStack(spacing: 12) {
                                AvatarView(name: c.name(for: me), photoUrl: c.photoUrl(for: me), size: 42)
                                Text(c.name(for: me)).font(.system(size: 17, weight: .medium)).lineLimit(1)
                                Spacer()
                                Button {
                                    CallService.shared.startCall(to: c.otherUid(me),
                                                                 name: c.name(for: me),
                                                                 photo: c.photoUrl(for: me))
                                    dismiss()
                                } label: {
                                    Image(systemName: "phone").font(.system(size: 20)).foregroundStyle(.tint)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("New Call")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search name")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct ChatsView: View {
    var onSignOut: () -> Void
    init(onSignOut: @escaping () -> Void = {}) { self.onSignOut = onSignOut }
    private var repo = ConversationsRepository.shared
    private var profile = ProfileStore.shared
    private var router = AppRouter.shared
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
                    return a.displayUpdatedAt(me) > b.displayUpdatedAt(me)
                }
                return a.displayUpdatedAt(me) > b.displayUpdatedAt(me)   // recency (frozen if blocked)
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
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)   // clean, no row lines (like Signal)
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
                        // Long-press menu (like Telegram/Signal) — same actions as the swipes.
                        .contextMenu {
                            Button { Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) } } label: {
                                Label(conv.isPinned(me) ? "Unpin" : "Pin", systemImage: "pin")
                            }
                            if conv.unread(me) > 0 {
                                Button { Task { await ChatService.resetUnread(conv.id) } } label: {
                                    Label("Mark as Read", systemImage: "envelope.open")
                                }
                            } else {
                                Button { Task { await ChatService.markUnread(conv.id) } } label: {
                                    Label("Mark as Unread", systemImage: "envelope.badge")
                                }
                            }
                            Button { pendingMute = conv } label: { Label("Mute", systemImage: "bell.slash") }
                            Button { Task { await ChatService.setArchived(conv.id, true) } } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            Button(role: .destructive) { pendingDelete = conv } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
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
        .onAppear { repo.start(); openPendingChat() }
        .onChange(of: router.pendingChatId) { _, _ in openPendingChat() }
        .onChange(of: repo.conversations.count) { _, _ in openPendingChat() }   // retry once chats load
    }

    // Open a chat from a notification tap. Stays pending until the chat list loads
    // so we can resolve name/photo, then routes straight to it.
    private func openPendingChat() {
        guard let cid = router.pendingChatId,
              let conv = repo.conversations.first(where: { $0.id == cid }) else { return }
        var p = NavigationPath()
        p.append(ChatTarget(id: cid, name: conv.name(for: me), photo: conv.photoUrl(for: me)))
        path = p
        router.pendingChatId = nil
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
        if conv.leaksBlocked(me) { return "" }   // don't leak a blocked person's message into the list
        let decoded = Crypto.shared.decrypt(conv.lastMessageCipher, cid: conv.id)
        return decoded.isEmpty ? "Say hello 👋" : decoded
    }
    private var unread: Int { conv.isBlockedByMe(me) ? 0 : conv.unread(me) }   // silent block: no badge

    private var timeStr: String {
        let ms = conv.displayUpdatedAt(me)   // frozen at block time for blocked chats
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
        // Spec: 56pt avatar, 12pt avatar→text gap, 8pt text→time/badge gap, 74pt row.
        HStack(spacing: 12) {
            AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(conv.name(for: me))
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timeStr)
                        .font(.system(size: 12))
                        .foregroundStyle(unread > 0 ? Theme.accent(dark) : .secondary)
                }
                HStack(spacing: 8) {
                    Text(preview)
                        .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    if unread > 0 {
                        Text("\(min(unread, 99))")
                            .font(.caption2.bold()).foregroundColor(Theme.onAccent(dark))
                            .padding(.horizontal, 5)
                            .frame(minWidth: 19, minHeight: 19)   // 19×19 min badge
                            .background(Theme.accent(dark)).clipShape(Capsule())
                    }
                }
            }
        }
        .frame(height: 74)   // fixed row height per spec
    }
}
