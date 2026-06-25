import SwiftUI
import UIKit

// Native TabView keeps both tabs permanently mounted -> the header avatar never
// unmounts/blinks on tab switch (the RN bug, solved structurally).
struct MainShell: View {
    var onSignOut: () -> Void
    private var call: CallService { CallService.shared }
    private var profile = ProfileStore.shared
    @State private var settingsIcon: UIImage?
    @State private var tab = 0

    init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

    var body: some View {
        // iOS 26 gets the new `Tab` API: floating Liquid-Glass pill (Chats · Calls · Settings)
        // with a native selected-tab highlight, plus the `.search` role tab drawn as the
        // SEPARATE circular button detached to the right. Older OS (deployment target 17.0)
        // can't use the `Tab` API, so it falls back to the classic `.tabItem` bar with a
        // normal 4th Search tab — same screens, just not the floating/detached styling.
        Group {
            if #available(iOS 26.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        // Call UI is mounted at the root (CallContainer in RootView) so it survives all
        // navigation. Here we only start listening for incoming calls.
        .onAppear { call.observeIncoming() }
        .task(id: profile.me?.photoUrl) { await loadSettingsIcon() }
    }

    // Your profile photo as the Settings tab icon (full-color circle); falls back to a
    // person glyph — outline when inactive, filled when this tab is active. SwiftUI does NOT
    // auto-swap a base SF Symbol to its .fill on selection (it only tints), so we pick it.
    @ViewBuilder private var settingsTabLabel: some View {
        Label {
            Text("Settings")
        } icon: {
            if let ui = settingsIcon {
                Image(uiImage: ui).renderingMode(.original)
            } else {
                Image(systemName: tab == 2 ? "person.crop.circle.fill" : "person.crop.circle")
            }
        }
    }

    @available(iOS 26.0, *)
    private var modernTabView: some View {
        TabView(selection: $tab) {
            Tab("Chats", systemImage: tab == 0 ? "message.fill" : "message", value: 0) {
                ChatsView(onSignOut: onSignOut)
            }
            Tab("Calls", systemImage: tab == 1 ? "phone.fill" : "phone", value: 1) {
                CallsView()
            }
            Tab(value: 2) {
                SettingsView(onSignOut: onSignOut, asTab: true)
            } label: {
                settingsTabLabel
            }
            // Detached circular search button (native iOS 26 search role) → global chat search.
            Tab(value: 3, role: .search) {
                ChatSearchView()
            }
        }
    }

    private var legacyTabView: some View {
        TabView(selection: $tab) {
            ChatsView(onSignOut: onSignOut)
                .tabItem { Label("Chats", systemImage: tab == 0 ? "message.fill" : "message") }
                .tag(0)
            CallsView()
                .tabItem { Label("Calls", systemImage: tab == 1 ? "phone.fill" : "phone") }
                .tag(1)
            SettingsView(onSignOut: onSignOut, asTab: true)
                .tabItem { settingsTabLabel }
                .tag(2)
            ChatSearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(3)
        }
    }

    private func loadSettingsIcon() async {
        guard let s = profile.me?.photoUrl, let url = URL(string: s),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return }
        let circ = img.circularIcon(28)   // tab-icon size — 56 overflowed onto the label
        await MainActor.run { settingsIcon = circ }
    }
}

// Render a circular, aspect-filled thumbnail for use as a (non-tinted) tab-bar icon.
private extension UIImage {
    func circularIcon(_ size: CGFloat) -> UIImage {
        let s = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: s).image { _ in
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: s)).addClip()
            let scale = Swift.max(s.width / self.size.width, s.height / self.size.height)
            let d = CGSize(width: self.size.width * scale, height: self.size.height * scale)
            self.draw(in: CGRect(x: (s.width - d.width) / 2, y: (s.height - d.height) / 2,
                                 width: d.width, height: d.height))
        }.withRenderingMode(.alwaysOriginal)
    }
}

// Native Phone-app-style call history (mockup IMG_4467): All / Missed segmented filter,
// search, rows with avatar, name (red if missed), direction, time, and an info button.
// Tap a row to call back; (i) opens the contact. Indigo brand kept.
struct CallsView: View {
    @State private var repo = CallsRepository.shared
    @State private var filter = 0            // 0 = All, 1 = Missed
    @State private var profileTarget: CallEntry?
    @State private var showNew = false

    private var shown: [CallEntry] {
        filter == 1 ? repo.calls.filter { $0.missed } : repo.calls
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
                            CallHistoryRow(
                                call: call,
                                onProfile: { profileTarget = call },
                                onCall: {
                                    CallService.shared.startCall(to: call.otherUid, name: call.name, photo: call.photoUrl)
                                }
                            )
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 56)   // tight, compact rows
                }
            }
            .navigationTitle("Calls")
            // Search moved to the global search tab (the detached circle), so the old
            // in-page search FAB + inline search bar were removed from Calls too.
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
            // Tapping a row pushes the contact's profile (back chevron, native). Calling
            // back happens only via the round phone button on the row.
            .navigationDestination(item: $profileTarget) { c in
                ContactInfoView(cid: c.cid, name: c.name, photoUrl: c.photoUrl, source: .calls)
            }
            .sheet(isPresented: $showNew) { NewCallView() }
        }
    }
}

struct CallHistoryRow: View {
    let call: CallEntry
    var onProfile: () -> Void
    var onCall: () -> Void

    private var directionIcon: String { call.mine ? "arrow.up.right" : "arrow.down.left" }
    private var directionText: String { call.missed ? "Missed" : (call.mine ? "Outgoing" : "Incoming") }

    var body: some View {
        HStack(spacing: 12) {
            // Whole left area (avatar, name, direction, time) → opens the contact profile.
            Button(action: onProfile) {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Round phone button → the ONLY thing that calls back.
            Button(action: onCall) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
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
    @State private var chatFilter = 0   // 0 = all, 1 = unread
    @State private var path = NavigationPath()
    @State private var pendingDelete: Conversation?
    @State private var pendingMute: Conversation?
    // Multi-select edit mode (Telegram-style).
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showArchived = false
    @State private var showDeleteSelected = false
    @State private var showCompose = false
    @State private var viewerGroup: StoryGroup?
    // WhatsApp-style header fade: hide the nav-bar icons while a chat is pushed so they
    // don't float statically over the screen during the interactive swipe-back. Driven by
    // navigation depth — a non-empty path (which holds through the ENTIRE drag) keeps them
    // hidden; they fade back only when the list is fully back (path empty again on commit).
    @State private var showHeaderIcons = true

    // Drops the toolbar icons to opacity 0 the instant we leave the list and fades them
    // back when it re-appears — without this SwiftUI keeps them pinned over the transition.
    private struct SwipeFade: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            content.opacity(on ? 1 : 0).animation(.easeInOut(duration: 0.15), value: on)
        }
    }

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }

    private var visible: [Conversation] {
        repo.conversations
            .filter { !$0.isCleared(me) && !$0.isArchived(me) }
            .filter { chatFilter == 0 || $0.unread(me) > 0 }   // Filter: All / Unread
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


    // Native nav bar with a crisp circle avatar — glass stripped via the iOS 26
    // opt-out, same as the chat header. Keeps the large "Chats" title + smooth
    // push transitions instead of a hand-rolled bar.
    // Avatar dropdown menu: Select Chats / Settings / Archive (Telegram-style).
    // Left: Edit (multi-select). Settings moved to its own tab, so no avatar here anymore.
    private var editButton: some View {
        Button("Edit") { selecting = true }.tint(.primary)
    }
    // Right: filter the list (All / Unread) + reach Archived.
    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $chatFilter) {
                Label("All Chats", systemImage: "bubble.left.and.bubble.right").tag(0)
                Label("Unread", systemImage: "circlebadge.fill").tag(1)
            }
            Divider()
            Button { showArchived = true } label: { Label("Archived", systemImage: "archivebox") }
        } label: {
            Image(systemName: chatFilter == 1 ? "line.3.horizontal.decrease.circle.fill"
                                              : "line.3.horizontal.decrease.circle")
                .font(.system(size: 18))
        }
        .tint(.primary)
    }
    private var composeButton: some View {
        Button { showNew = true } label: {
            Image(systemName: "square.and.pencil").font(.system(size: 18))
        }
        .tint(.primary)   // glass circle (default), black glyph
    }

    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        if selecting {
            // Minimal X close (replaces "Cancel"); no "Select All" — tap rows to select.
            ToolbarItem(placement: .topBarLeading) {
                Button { exitSelect() } label: { Image(systemName: "xmark") }.tint(.primary)
            }
            ToolbarItem(placement: .principal) {
                Text(selection.isEmpty ? "Select Chats" : "\(selection.count) Selected").font(.headline)
            }
        } else if #available(iOS 26.0, *) {
            // Edit keeps its native Liquid Glass capsule (no sharedBackgroundVisibility opt-out).
            ToolbarItem(placement: .topBarLeading) { editButton.modifier(SwipeFade(on: showHeaderIcons)) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu.modifier(SwipeFade(on: showHeaderIcons))
                composeButton.modifier(SwipeFade(on: showHeaderIcons))
            }
        } else {
            ToolbarItem(placement: .topBarLeading) { editButton.modifier(SwipeFade(on: showHeaderIcons)) }
            ToolbarItemGroup(placement: .topBarTrailing) {
                filterMenu.modifier(SwipeFade(on: showHeaderIcons))
                composeButton.modifier(SwipeFade(on: showHeaderIcons))
            }
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
        let rows = visible
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
    private func selectAll() { selection = Set(visible.map { $0.id }) }

    // System action list for a chat row's context menu (HIG order + SF Symbols).
    @ViewBuilder private func chatMenu(_ conv: Conversation) -> some View {
        if conv.unread(me) > 0 {
            Button { Task { await ChatService.resetUnread(conv.id) } } label: {
                Label("Read", systemImage: "envelope.open")
            }
        } else {
            Button { Task { await ChatService.markUnread(conv.id) } } label: {
                Label("Unread", systemImage: "envelope.badge")
            }
        }
        Button { pendingMute = conv } label: { Label("Mute", systemImage: "bell.slash") }
        Button { Task { await ChatService.setPinned(conv.id, !conv.isPinned(me)) } } label: {
            Label(conv.isPinned(me) ? "Unpin" : "Pin", systemImage: "pin")
        }
        Button { Task { await ChatService.setArchived(conv.id, true) } } label: {
            Label("Archive", systemImage: "archivebox")
        }
        Button(role: .destructive) { pendingDelete = conv } label: {
            Label("Delete", systemImage: "trash")
        }
    }
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
                      // Stories row on top of Chats (My Status + friends' rings).
                      StoriesRow(meName: profile.me?.name ?? "You", mePhoto: profile.me?.photoUrl,
                                 onCompose: { showCompose = true },
                                 onOpen: { g in viewerGroup = g })
                          .listRowInsets(EdgeInsets())
                          .listRowSeparator(.hidden)
                          .moveDisabled(true)
                          .deleteDisabled(true)
                      ForEach(visible) { conv in
                        // Full-row Button instead of a NavigationLink: a NavigationLink in a
                        // List always draws the trailing disclosure chevron (the arrow). A
                        // plain Button does not, and in edit mode it is auto-disabled so the
                        // List's native multi-select still toggles via the row tag.
                        Button {
                            path.append(ChatTarget(id: conv.id, name: conv.name(for: me),
                                                   photo: conv.photoUrl(for: me)))
                        } label: {
                            ChatRow(conv: conv, me: me, dark: dark)
                        }
                        .buttonStyle(.plain)
                        .tag(conv.id)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)   // clean, no row lines (like Signal)
                        .moveDisabled(!conv.isPinned(me))   // only pinned chats can be dragged
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
                        // Native peek + system actions. The preview-based API coexists with
                        // swipeActions (the legacy closure form was eating the trailing swipe).
                        .contextMenu {
                            chatMenu(conv)
                        } preview: {
                            ChatPeekPreview(conv: conv, me: me, dark: dark)
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
            // Search now lives in its own tab (the detached search circle), so the old
            // in-list search FAB + inline search bar were removed.
            .toolbar { homeToolbar }
            // Hide the header icons whenever a chat is on the stack (incl. the swipe-back
            // drag); reveal them only when we're fully back at the root list.
            .onChange(of: path.count) { showHeaderIcons = path.isEmpty }
            .sheet(isPresented: $showCompose) {
                StoryComposeSheet { Task { await StoriesRepository.shared.load() } }
            }
            .fullScreenCover(item: $viewerGroup) { g in
                StoryViewer(group: g) {
                    viewerGroup = nil
                    Task { await StoriesRepository.shared.load() }   // refresh seen rings
                }
            }
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
    private var muted: Bool { conv.isMuted(me, now: Date().timeIntervalSince1970 * 1000) }

    // WhatsApp-style ticks for MY last message: single grey = sent, double accent = read.
    @ViewBuilder private var ticksView: some View {
        let read = conv.lastReadByOther(me)
        HStack(spacing: -3) {
            Image(systemName: "checkmark")
            if read { Image(systemName: "checkmark") }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(read ? Theme.accent(dark) : Color.secondary)
    }

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
        // 56pt avatar; up to 2 preview lines; mute/pin/tick indicators inline.
        HStack(spacing: 12) {
            AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(conv.name(for: me))
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Text(timeStr)
                        .font(.system(size: 12))
                        .foregroundStyle(unread > 0 ? Theme.accent(dark) : .secondary)
                }
                HStack(alignment: .top, spacing: 4) {
                    if conv.lastIsMine(me) { ticksView.padding(.top, 2) }
                    Text(preview)
                        .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    if conv.isPinned(me) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
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
        .frame(minHeight: 76)
        .padding(.vertical, 2)
        .padding(.horizontal, 16)   // 16pt gutter moved inside the cell (row insets are now
                                    // zero) so the reorder drag preview matches the cell width
                                    // and stays locked to the vertical axis (no horizontal drift)
    }
}

// Global chat search — the screen behind the detached search-circle tab (iOS 26 `.search`
// role). Real search: filters every non-cleared conversation by contact name; tapping a
// result opens that chat. Empty query shows guidance; no matches shows the native no-results.
struct ChatSearchView: View {
    private var repo = ConversationsRepository.shared
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var path = NavigationPath()

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var results: [Conversation] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        return repo.conversations
            .filter { !$0.isCleared(me) }
            .filter { $0.name(for: me).lowercased().contains(q) }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if trimmed.isEmpty {
                    ContentUnavailableView("Search your chats", systemImage: "magnifyingglass",
                                           description: Text("Find a conversation by name."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: trimmed)
                } else {
                    List(results) { conv in
                        Button {
                            path.append(ChatTarget(id: conv.id, name: conv.name(for: me),
                                                   photo: conv.photoUrl(for: me)))
                        } label: {
                            ChatRow(conv: conv, me: me, dark: dark)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ChatTarget.self) { t in
                ThreadView(cid: t.id, title: t.name, photoUrl: t.photo).id(t.id)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search chats")
        .onAppear { repo.start() }
    }
}
