import SwiftUI

// New Group: name the group, multi-select members from people you've chatted with
// (or search), then create. Native-styled to match New Message.
struct NewGroupView: View {
    let onOpen: (ChatTarget) -> Void
    init(onOpen: @escaping (ChatTarget) -> Void = { _ in }) { self.onOpen = onOpen }

    struct Person: Identifiable, Hashable { let id: String; let name: String; let photo: String? }

    @Environment(\.dismiss) private var dismiss
    private var convRepo = ConversationsRepository.shared
    @State private var groupName = ""
    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var searching = false
    @State private var selected: [String: Person] = [:]   // uid -> person
    @State private var creating = false
    @State private var error: String?

    private var me: String { AuthService.shared.uid ?? "" }

    // 1:1 contacts (you can't pull members out of another group), de-duped + sorted.
    private var contacts: [Person] {
        convRepo.conversations
            .filter { !$0.isGroup && !$0.isCleared(me) }
            .compactMap { c in
                let uid = c.otherUid(me)
                guard !uid.isEmpty else { return nil }
                return Person(id: uid, name: c.name(for: me), photo: c.photoUrl(for: me))
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty && !creating
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Group name", text: $groupName)
                        .textInputAutocapitalization(.words)
                }

                if !selected.isEmpty {
                    Section("Members · \(selected.count + 1)") {   // +1 = you
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(Array(selected.values)) { p in
                                    VStack(spacing: 4) {
                                        ZStack(alignment: .topTrailing) {
                                            AvatarView(name: p.name, photoUrl: p.photo, size: 52)
                                            Button { selected[p.id] = nil } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 18))
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .gray)
                                            }
                                            .offset(x: 4, y: -4)
                                        }
                                        Text(p.name).font(.caption2).lineLimit(1).frame(width: 56)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section(query.isEmpty ? "Add members" : "Results") {
                    let rows: [Person] = query.isEmpty
                        ? contacts
                        : results.map { Person(id: $0.id, name: $0.name.isEmpty ? $0.handle : $0.name, photo: $0.photoUrl) }
                    if rows.isEmpty {
                        if searching {
                            ChatListSkeleton()
                        } else {
                            Text(query.isEmpty ? "Chat with someone first to add them here." : "No one found")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rows) { p in
                        Button { toggle(p) } label: {
                            HStack(spacing: 12) {
                                AvatarView(name: p.name, photoUrl: p.photo, size: 40)
                                Text(p.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected[p.id] != nil ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected[p.id] != nil ? Color.accentColor : .secondary)
                            }
                        }
                    }
                }

                if let error { Text(error).foregroundStyle(.red) }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Name or username")
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { create() }.disabled(!canCreate).fontWeight(.semibold)
                }
            }
            .overlay { if creating { ProgressView().controlSize(.large) } }
            .onChange(of: query) { _, q in search(q) }
        }
    }

    private func toggle(_ p: Person) {
        if selected[p.id] != nil { selected[p.id] = nil } else { selected[p.id] = p }
    }

    private func search(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; searching = false; return }
        searching = true
        Task {
            var r = await ChatService.searchUsers(prefix: trimmed)
            if r.isEmpty, let exact = await ChatService.findByHandle(trimmed) { r = [exact] }
            await MainActor.run {
                guard query.trimmingCharacters(in: .whitespaces) == trimmed else { return }
                results = r.filter { $0.id != me }
                searching = false
            }
        }
    }

    private func create() {
        let name = groupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !selected.isEmpty else { return }
        creating = true; error = nil
        Task {
            do {
                let cid = try await ChatService.createGroup(title: name, memberIds: Array(selected.keys))
                await MainActor.run {
                    creating = false
                    onOpen(ChatTarget(id: cid, name: name, photo: nil))
                }
            } catch {
                await MainActor.run { self.error = "Could not create group. Try again."; creating = false }
            }
        }
    }
}
