import SwiftUI
import PhotosUI

// Group info: avatar (admin can change) + name (admin can rename), member list with Admin
// badges, admin actions (add / remove / promote), and Leave. Live from ConversationsRepository.
struct GroupInfoView: View {
    let cid: String
    init(cid: String) { self.cid = cid }
    @Environment(\.dismiss) private var dismiss
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }

    @State private var showRename = false
    @State private var newName = ""
    @State private var showDescEdit = false
    @State private var descText = ""
    @State private var showMute = false
    @State private var showDisappear = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var showAdd = false
    @State private var memberAction: MemberAction?
    @State private var confirmLeave = false
    @State private var confirmClear = false
    @State private var media: [Message] = []
    @State private var showAllMedia = false

    struct MemberAction: Identifiable { let id: String; let name: String; let isAdmin: Bool }

    private var conv: Conversation? { repo.conversations.first { $0.id == cid } }
    private var iAmAdmin: Bool { conv?.isAdmin(me) ?? false }

    var body: some View {
        Group {   // pushed from the chat header → uses the parent nav bar (no nested stack)
            groupBody
                .alert("Rename group", isPresented: $showRename) {
                    TextField("Group name", text: $newName)
                    Button("Save") { let t = newName; Task { try? await ChatService.renameGroup(cid: cid, title: t) } }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Group description", isPresented: $showDescEdit) {
                    TextField("Description", text: $descText)
                    Button("Save") { let t = descText; Task { try? await ChatService.setGroupDescription(cid: cid, text: t) } }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Mute Notifications", isPresented: $showMute, titleVisibility: .visible) {
                    Button("Mute for 1 hour")  { Task { await ChatService.setMute(cid, until: ChatService.muteUntil(1)) } }
                    Button("Mute for 8 hours") { Task { await ChatService.setMute(cid, until: ChatService.muteUntil(8)) } }
                    Button("Mute for 1 week")  { Task { await ChatService.setMute(cid, until: ChatService.muteUntil(168)) } }
                    Button("Mute Always")      { Task { await ChatService.setMute(cid, until: ChatService.muteUntil(nil)) } }
                    Button("Unmute")           { Task { await ChatService.setMute(cid, until: 0) } }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Disappearing Messages", isPresented: $showDisappear, titleVisibility: .visible) {
                    Button("Off")     { Task { await ChatService.setDisappear(cid, seconds: 0) } }
                    Button("1 Day")   { Task { await ChatService.setDisappear(cid, seconds: 86_400) } }
                    Button("1 Week")  { Task { await ChatService.setDisappear(cid, seconds: 604_800) } }
                    Button("Cancel", role: .cancel) {}
                }
        }
    }

    // Split out so the body's modifier chain stays small enough for the type-checker.
    private var groupBody: some View {
        List {
            headerSection
            settingsSection
            mediaSection
            membersSection
            leaveSection
        }
        .navigationTitle("Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog(memberAction?.name ?? "",
                            isPresented: Binding(get: { memberAction != nil }, set: { if !$0 { memberAction = nil } }),
                            titleVisibility: .visible, presenting: memberAction) { m in
            memberActions(m)
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
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self) {
                    try? await ChatService.uploadGroupAvatar(cid: cid, data: d)
                }
            }
        }
        .task { media = await ChatService.sharedMedia(cid) }
        .sheet(isPresented: $showAllMedia) { SharedMediaGridView(cid: cid, media: media) }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                if iAmAdmin {
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            AvatarView(name: conv?.title ?? "Group", photoUrl: conv?.avatarUrl, size: 88)
                            Image(systemName: "camera.circle.fill")
                                .font(.system(size: 26)).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    AvatarView(name: conv?.title ?? "Group", photoUrl: conv?.avatarUrl, size: 88)
                }
                Text(conv?.title ?? "Group").font(.title2.weight(.bold))
                Text(conv?.memberCountLabel ?? "").font(.subheadline).foregroundStyle(.secondary)
                // Description (tap to add/edit if admin) — like Signal/Telegram group info.
                if let d = conv?.groupDescription, !d.isEmpty {
                    Text(d).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .onTapGesture { if iAmAdmin { descText = d; showDescEdit = true } }
                } else if iAmAdmin {
                    Button("Add group description…") { descText = ""; showDescEdit = true }
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private var membersSection: some View {
        Section("\(conv?.users.count ?? 0) Members") {
            if iAmAdmin {
                Button { showAdd = true } label: { Label("Add Members", systemImage: "person.badge.plus") }
            }
            ForEach(sortedMembers, id: \.self) { uid in memberRow(uid) }
        }
    }

    private var settingsSection: some View {
        Section {
            Button { showMute = true } label: {
                Label("Mute Notifications", systemImage: "bell.slash")
                    .foregroundStyle(.primary)
            }
            // Disappearing messages is a group-wide setting → admin-only to change.
            if iAmAdmin {
                Button { showDisappear = true } label: {
                    HStack {
                        Label("Disappearing Messages", systemImage: "timer")
                        Spacer()
                        Text(disappearLabel).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
            } else if (conv?.disappearSeconds ?? 0) > 0 {
                HStack {
                    Label("Disappearing Messages", systemImage: "timer")
                    Spacer()
                    Text(disappearLabel).foregroundStyle(.secondary)
                }
            }
            // Announcement mode (admin): only admins can send. Enforced in the message rules.
            if iAmAdmin {
                Toggle(isOn: Binding(
                    get: { conv?.onlyAdminsSend ?? false },
                    set: { v in Task { try? await ChatService.setOnlyAdminsSend(cid: cid, v) } }
                )) {
                    Label("Only admins can send", systemImage: "megaphone")
                }
            }
        }
    }

    private var disappearLabel: String {
        switch conv?.disappearSeconds ?? 0 {
        case 86_400:  return "1 day"
        case 604_800: return "1 week"
        default:      return "Off"
        }
    }

    @ViewBuilder private var mediaSection: some View {
        if !media.isEmpty {
            Section("Media") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(media.prefix(12)) { m in
                            if let url = m.imageUrl {
                                SecureImageView(imageUrl: url, enc: m.enc, cid: cid)
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                Button("See All") { showAllMedia = true }.tint(.primary)
            }
        }
    }

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear Chat", systemImage: "trash")
            }
            Button(role: .destructive) { confirmLeave = true } label: {
                Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button(role: .destructive) {
                Task { await ChatService.report(reportedUid: conv?.admins.first ?? "", cid: cid, reason: "group") }
            } label: {
                Label("Report Group", systemImage: "exclamationmark.bubble")
            }
        } footer: {
            if let label = createdByLabel {
                Text(label).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 6)
            }
        }
        .confirmationDialog("Clear this chat?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Chat", role: .destructive) { Task { await ChatService.clearMyMessages(cid) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // "Created by you · 26 Jun 2026" footer, like the reference group screens.
    private var createdByLabel: String? {
        guard let conv, conv.isGroup, !conv.createdBy.isEmpty else { return nil }
        let who = conv.createdBy == me ? "you" : (conv.names[conv.createdBy] ?? "someone")
        guard let d = conv.createdAt else { return "Created by \(who)" }
        let f = DateFormatter(); f.dateStyle = .medium
        return "Created by \(who) · \(f.string(from: d))"
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if iAmAdmin {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { newName = conv?.title ?? ""; showRename = true }
            }
        }
    }

    @ViewBuilder private func memberActions(_ m: MemberAction) -> some View {
        if m.isAdmin {
            Button("Remove as Admin") { Task { try? await ChatService.demoteGroupAdmin(cid: cid, uid: m.id, name: m.name) } }
        } else {
            Button("Make Admin") { Task { try? await ChatService.promoteGroupAdmin(cid: cid, uid: m.id, name: m.name) } }
        }
        Button("Remove from Group", role: .destructive) {
            Task { try? await ChatService.removeGroupMember(cid: cid, uid: m.id, name: m.name) }
        }
        Button("Cancel", role: .cancel) {}
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
    init(cid: String, existing: Set<String>) { self.cid = cid; self.existing = existing }
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
