import SwiftUI

// Group info: avatar + name (admin can rename), member list with Admin badges, admin
// actions (add / remove / promote), and Leave. Reads live from ConversationsRepository.
struct GroupInfoView: View {
    let cid: String
    @Environment(\.dismiss) private var dismiss
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }

    @State private var showRename = false
    @State private var newName = ""
    @State private var showAdd = false
    @State private var memberAction: MemberAction?
    @State private var confirmLeave = false

    struct MemberAction: Identifiable { let id: String; let name: String; let isAdmin: Bool }

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var iAmAdmin: Bool { conv?.isAdmin(me) ?? false }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        AvatarView(name: conv?.title ?? "Group", photoUrl: conv?.avatarUrl, size: 88)
                        Text(conv?.title ?? "Group").font(.title2.weight(.bold))
                        Text(conv?.memberCountLabel ?? "").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("\(conv?.users.count ?? 0) Members") {
                    if iAmAdmin {
                        Button { showAdd = true } label: {
                            Label("Add Members", systemImage: "person.badge.plus")
                        }
                    }
                    ForEach(sortedMembers, id: \.self) { uid in
                        memberRow(uid)
                    }
                }

                Section {
                    Button(role: .destructive) { confirmLeave = true } label: {
                        Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if iAmAdmin {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { newName = conv?.title ?? ""; showRename = true }
                    }
                }
            }
            .alert("Rename group", isPresented: $showRename) {
                TextField("Group name", text: $newName)
                Button("Save") { let t = newName; Task { try? await ChatService.renameGroup(cid: cid, title: t) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(memberAction?.name ?? "",
                                isPresented: Binding(get: { memberAction != nil }, set: { if !$0 { memberAction = nil } }),
                                titleVisibility: .visible, presenting: memberAction) { m in
                if !m.isAdmin {
                    Button("Make Admin") { Task { try? await ChatService.promoteGroupAdmin(cid: cid, uid: m.id, name: m.name) } }
                }
                Button("Remove from Group", role: .destructive) {
                    Task { try? await ChatService.removeGroupMember(cid: cid, uid: m.id, name: m.name) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave", role: .destructive) {
                    Task { try? await ChatService.leaveGroup(cid: cid); await MainActor.run { dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showAdd) {
                AddMembersSheet(cid: cid, existing: Set(conv?.users ?? []))
            }
        }
    }

    private var sortedMembers: [String] {
        (conv?.users ?? []).sorted { a, b in
            if a == me { return true }
            if b == me { return false }
            let aAdmin = conv?.isAdmin(a) ?? false, bAdmin = conv?.isAdmin(b) ?? false
            if aAdmin != bAdmin { return aAdmin }
            return name(a).lowercased() < name(b).lowercased()
        }
    }

    private func name(_ uid: String) -> String {
        uid == me ? "You" : (conv?.names[uid] ?? "User")
    }

    @ViewBuilder private func memberRow(_ uid: String) -> some View {
        let isAdmin = conv?.isAdmin(uid) ?? false
        let canManage = iAmAdmin && uid != me
        Button {
            if canManage { memberAction = MemberAction(id: uid, name: conv?.names[uid] ?? "User", isAdmin: isAdmin) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: name(uid), photoUrl: conv?.photos[uid], size: 40)
                Text(name(uid)).foregroundStyle(.primary)
                Spacer()
                if isAdmin { Text("Admin").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .disabled(!canManage)
    }
}

// Multi-select sheet to add 1:1 contacts who aren't already in the group.
struct AddMembersSheet: View {
    let cid: String
    let existing: Set<String>
    @Environment(\.dismiss) private var dismiss
    private var convRepo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    @State private var selected = Set<String>()

    private var candidates: [(id: String, name: String, photo: String?)] {
        convRepo.conversations
            .filter { !$0.isGroup && !$0.isCleared(me) }
            .compactMap { c in
                let u = c.otherUid(me)
                guard !u.isEmpty, !existing.contains(u) else { return nil }
                return (u, c.name(for: me), c.photoUrl(for: me))
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("Everyone you've chatted with is already in this group.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates, id: \.id) { p in
                    Button { toggle(p.id) } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: p.name, photoUrl: p.photo, size: 40)
                            Text(p.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(p.id) ? Color.accentColor : .secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let ids = Array(selected)
                        Task { try? await ChatService.addGroupMembers(cid: cid, add: ids) }
                        dismiss()
                    }
                    .disabled(selected.isEmpty).fontWeight(.semibold)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
