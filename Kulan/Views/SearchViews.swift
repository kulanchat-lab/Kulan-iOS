import SwiftUI
import FirebaseFirestore
import FirebaseAuth

// The single search-circle tab (iOS 26 `.search` role) routes to a context-specific
// search based on which main tab the user came from:
//   Chats    -> full message search (names + the text of every message)
//   Calls    -> everyone you've chatted with, tap to start a call
//   Settings -> search within Settings
extension View {
    // Auto-focus a `.searchable` field so the keyboard opens the moment the search
    // page appears (no second tap). `searchFocused` is iOS 18+, so older OS just no-ops.
    @ViewBuilder func autoFocusSearch(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(iOS 18.0, *) { self.searchFocused(focused) } else { self }
    }
}

struct SearchHubView: View {
    let context: Int            // 0 = Chats, 1 = Calls, 2 = Settings
    var onSignOut: () -> Void = {}
    var onCancel: () -> Void = {}   // tapping the search field's Cancel returns to the prior tab

    var body: some View {
        switch context {
        case 1: ContactsSearchView(onCancel: onCancel)
        case 2: SettingsSearchView(onSignOut: onSignOut, onCancel: onCancel)
        default: ChatSearchView(onCancel: onCancel)
        }
    }
}

// Watches the native search field; when the user cancels (search deactivates with an
// empty query and nothing pushed), it calls onCancel so we can return to the prior tab.
private struct SearchCancelWatcher: View {
    var canReturn: () -> Bool
    var onCancel: () -> Void
    @Environment(\.isSearching) private var isSearching
    @State private var wasSearching = false
    var body: some View {
        Color.clear
            .onChange(of: isSearching) { _, now in
                if now { wasSearching = true }
                else if wasSearching {
                    wasSearching = false
                    if canReturn() { onCancel() }
                }
            }
    }
}

// MARK: - Chats: full message-history search

// One message that matched the query, carrying its chat context for display + tap.
struct MessageHit: Identifiable {
    let messageId: String
    let cid: String
    let chatName: String
    let photoUrl: String?
    let text: String
    let date: Date
    var id: String { cid + "/" + messageId }
}

// Searches names instantly + the decrypted text of every message across all chats.
// Message search is on-demand and bounded (most-recent page per chat) so it can't
// run away on a long history; it's debounced so typing doesn't refire per keystroke.
struct ChatSearchView: View {
    var onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    private var repo = ConversationsRepository.shared
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var corpus: [SearchableMessage] = []   // loaded once; filtered in memory
    @State private var loadingCorpus = false
    @State private var loadTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    // Cheap, instant name matches (no decryption needed).
    private var nameMatches: [Conversation] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        return repo.conversations
            .filter { !$0.isCleared(me) && $0.name(for: me).lowercased().contains(q) }
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    // Instant in-memory filter over the cached corpus — no network/decrypt per keystroke.
    private var hits: [MessageHit] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return [] }
        return corpus
            .filter { $0.text.lowercased().contains(q) }
            .sorted { $0.date > $1.date }
            .prefix(60)
            .map { MessageHit(messageId: $0.id, cid: $0.cid, chatName: $0.chatName,
                              photoUrl: $0.photoUrl, text: $0.text, date: $0.date) }
    }

    private var nothingFound: Bool { nameMatches.isEmpty && hits.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !nameMatches.isEmpty {
                    Section("Chats") {
                        ForEach(nameMatches) { conv in
                            Button { open(conv.id, conv.name(for: me), conv.photoUrl(for: me)) } label: {
                                ChatRow(conv: conv, me: me, dark: dark)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                    }
                }
                if !hits.isEmpty {
                    Section("Messages") {
                        ForEach(hits) { hit in
                            Button { open(hit.cid, hit.chatName, hit.photoUrl) } label: {
                                MessageHitRow(hit: hit)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if trimmed.isEmpty {
                    ContentUnavailableView("Search messages", systemImage: "magnifyingglass",
                                           description: Text("Search names and the text of every message."))
                } else if loadingCorpus && nothingFound {
                    ProgressView()
                } else if !loadingCorpus && nothingFound {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .background { SearchCancelWatcher(canReturn: { trimmed.isEmpty && path.isEmpty }, onCancel: onCancel) }
            .navigationDestination(for: ChatTarget.self) { t in
                ThreadView(cid: t.id, title: t.name, photoUrl: t.photo).id(t.id)
            }
        }
        .searchable(text: $query,
                    prompt: "Search messages")
        .autoFocusSearch($searchFocused)
        .onAppear {
            repo.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { searchFocused = true }
            loadTask?.cancel()
            loadingCorpus = corpus.isEmpty
            loadTask = Task {
                let loaded = await MessageSearch.loadCorpus(me: me)
                if Task.isCancelled { return }
                await MainActor.run { corpus = loaded; loadingCorpus = false }
            }
        }
    }

    private func open(_ cid: String, _ name: String, _ photo: String?) {
        path.append(ChatTarget(id: cid, name: name, photo: photo))
    }
}

private struct MessageHitRow: View {
    let hit: MessageHit
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: hit.chatName, photoUrl: hit.photoUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.chatName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(hit.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(hit.text).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// One cached, already-decrypted message (text only) — the unit for fast in-memory search.
struct SearchableMessage {
    let id: String
    let cid: String
    let chatName: String
    let photoUrl: String?
    let text: String
    let date: Date
}

// Loads the recent messages across all chats ONCE (decrypting ONLY the text field, not
// reactions/replies), so typing filters this in memory instead of re-querying Firestore
// and re-decrypting on every keystroke (the cause of the lag/freeze).
enum MessageSearch {
    private static let perChatLimit = 250

    static func loadCorpus(me: String) async -> [SearchableMessage] {
        let convs = await MainActor.run {
            ConversationsRepository.shared.conversations.filter { !$0.isCleared(me) }
        }
        let db = Firestore.firestore()
        var out: [SearchableMessage] = []
        for c in convs {
            if Task.isCancelled { break }
            _ = await Crypto.shared.preloadKey(c.otherUid(me))   // needed before decrypt
            guard let snap = try? await db.collection("conversations").document(c.id)
                .collection("messages")
                .order(by: "createdAt", descending: true)
                .limit(to: perChatLimit)
                .getDocuments() else { continue }
            let name = c.name(for: me), photo = c.photoUrl(for: me)
            for doc in snap.documents {
                let data = doc.data()
                let text = Crypto.shared.decrypt(data["text"] as? String ?? "", cid: c.id)
                guard !text.isEmpty else { continue }
                let date = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                out.append(SearchableMessage(id: doc.documentID, cid: c.id, chatName: name,
                                             photoUrl: photo, text: text, date: date))
            }
        }
        return out
    }
}

// MARK: - Calls: search anyone you've chatted with, tap to call

struct ContactsSearchView: View {
    var onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    private var repo = ConversationsRepository.shared
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var me: String { AuthService.shared.uid ?? "" }
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var results: [Conversation] {
        let q = trimmed.lowercased()
        let base = repo.conversations.filter { !$0.isCleared(me) }
        let list = q.isEmpty ? base : base.filter { $0.name(for: me).lowercased().contains(q) }
        return list.sorted { $0.name(for: me).lowercased() < $1.name(for: me).lowercased() }
    }

    var body: some View {
        NavigationStack {
            List(results) { conv in
                Button {
                    CallService.shared.startCall(to: conv.otherUid(me),
                                                 name: conv.name(for: me),
                                                 photo: conv.photoUrl(for: me))
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 46)
                        Text(conv.name(for: me)).font(.system(size: 16, weight: .medium))
                        Spacer()
                        Image(systemName: "phone.fill").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty {
                    if trimmed.isEmpty {
                        ContentUnavailableView("Call a contact", systemImage: "phone",
                                               description: Text("Search anyone you've chatted with to start a call."))
                    } else {
                        ContentUnavailableView.search(text: trimmed)
                    }
                }
            }
            .navigationTitle("Call")
            .navigationBarTitleDisplayMode(.inline)
            .background { SearchCancelWatcher(canReturn: { trimmed.isEmpty }, onCancel: onCancel) }
        }
        .searchable(text: $query,
                    prompt: "Search contacts")
        .autoFocusSearch($searchFocused)
        .onAppear { repo.start() }
        .task { try? await Task.sleep(nanoseconds: 350_000_000); searchFocused = true }
    }
}

// MARK: - Settings search

struct SettingsSearchView: View {
    var onSignOut: () -> Void
    var onCancel: () -> Void
    init(onSignOut: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) {
        self.onSignOut = onSignOut; self.onCancel = onCancel
    }
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let icon: String
        let keywords: String
        let dest: AnyView
    }

    private var entries: [Entry] {
        [
            Entry(title: "Account", icon: "person.crop.circle",
                  keywords: "account name username id sign out delete",
                  dest: AnyView(AccountSettingsView(onSignOut: onSignOut))),
            Entry(title: "My Profile", icon: "person.text.rectangle",
                  keywords: "profile bio photo edit stories",
                  dest: AnyView(MyProfileView())),
            Entry(title: "Linked Devices", icon: "laptopcomputer.and.iphone",
                  keywords: "devices sessions linked",
                  dest: AnyView(DevicesView())),
            Entry(title: "Notifications", icon: "bell.badge",
                  keywords: "notifications push sound vibrate preview",
                  dest: AnyView(NotificationsSettingsView())),
            Entry(title: "Appearance", icon: "paintbrush",
                  keywords: "appearance theme dark light",
                  dest: AnyView(AppearanceSettingsView())),
            Entry(title: "Stories", icon: "circle.dashed",
                  keywords: "stories status view receipts",
                  dest: AnyView(StorySettingsView())),
            Entry(title: "Privacy & Security", icon: "lock.shield",
                  keywords: "privacy security read receipts typing last seen app lock screen",
                  dest: AnyView(PrivacySettingsView())),
            Entry(title: "Blocked Users", icon: "hand.raised",
                  keywords: "blocked block users",
                  dest: AnyView(BlockedUsersView())),
            Entry(title: "Phone Number", icon: "phone",
                  keywords: "phone number privacy",
                  dest: AnyView(PhoneNumberPrivacyView())),
            Entry(title: "Help & About", icon: "questionmark.circle",
                  keywords: "help about version",
                  dest: AnyView(AboutView())),
        ]
    }

    private var results: [Entry] {
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.title.lowercased().contains(q) || $0.keywords.contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(results) { e in
                NavigationLink { e.dest } label: { Label(e.title, systemImage: e.icon) }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: trimmed) }
            }
            .navigationTitle("Search Settings")
            .navigationBarTitleDisplayMode(.inline)
            .background { SearchCancelWatcher(canReturn: { trimmed.isEmpty }, onCancel: onCancel) }
        }
        .searchable(text: $query,
                    prompt: "Search settings")
        .autoFocusSearch($searchFocused)
        .task { try? await Task.sleep(nanoseconds: 350_000_000); searchFocused = true }
    }
}
