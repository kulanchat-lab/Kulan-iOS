import SwiftUI

struct ChatTarget: Identifiable, Hashable {
    let id: String      // cid
    let name: String
    let photo: String?
}

struct NewChatView: View {
    let onOpen: (ChatTarget) -> Void
    init(onOpen: @escaping (ChatTarget) -> Void = { _ in }) { self.onOpen = onOpen }

    @Environment(\.dismiss) private var dismiss
    private var convRepo = ConversationsRepository.shared
    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var searching = false
    @State private var error: String?
    @State private var showScan = false

    private var me: String { AuthService.shared.uid ?? "" }
    private var recents: [Conversation] {
        Array(convRepo.conversations.filter { !$0.isCleared(me) }.prefix(15))
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }

                if query.isEmpty {
                    if recents.isEmpty {
                        ContentUnavailableView("Start a new chat", systemImage: "square.and.pencil",
                                               description: Text("Search a username to message someone."))
                    } else {
                        Section("Recent") {
                            ForEach(recents) { conv in
                                Button {
                                    onOpen(ChatTarget(id: conv.id, name: conv.name(for: me), photo: conv.photoUrl(for: me)))
                                } label: {
                                    personRow(name: conv.name(for: me), handle: nil, photo: conv.photoUrl(for: me))
                                }
                            }
                        }
                    }
                } else {
                    Section("Results") {
                        ForEach(results) { user in
                            Button { start(user) } label: {
                                personRow(name: user.name.isEmpty ? user.handle : user.name,
                                          handle: user.handle, photo: user.photoUrl)
                            }
                        }
                        // Only after the query has FINISHED with zero hits — never
                        // flashes "not found" while the lookup is still running.
                        if results.isEmpty {
                            if searching {
                                HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                            } else {
                                Text("No one found for “\(query)”").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search username")
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showScan = true } label: { Image(systemName: "qrcode.viewfinder") }
                }
            }
            .sheet(isPresented: $showScan) {
                ScanQRView { user in showScan = false; start(user) }
            }
            .onChange(of: query) { _, q in
                let trimmed = q.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { results = []; searching = false; return }
                searching = true
                Task {
                    var r = await ChatService.searchUsers(prefix: trimmed)
                    // Exact-handle fallback so "@ayaan" / full handles still resolve.
                    if r.isEmpty, let exact = await ChatService.findByHandle(trimmed) { r = [exact] }
                    await MainActor.run {
                        // Ignore stale results if the query moved on while we waited.
                        guard query.trimmingCharacters(in: .whitespaces) == trimmed else { return }
                        results = r
                        searching = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func personRow(name: String, handle: String?, photo: String?) -> some View {
        HStack(spacing: 12) {
            AvatarView(name: name, photoUrl: photo, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).foregroundStyle(.primary)
                if let handle, !handle.isEmpty {
                    Text("@\(handle)").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    // The conversation ID is deterministic, so open the thread INSTANTLY and
    // create/touch the conversation doc in the background — no network wait, no
    // step-back to the chat list.
    private func start(_ user: UserProfile) {
        let cid = ChatService.convId(me, user.id)
        onOpen(ChatTarget(id: cid, name: user.name.isEmpty ? user.handle : user.name, photo: user.photoUrl))
        Task { try? await ChatService.openConversation(other: user) }
    }
}
