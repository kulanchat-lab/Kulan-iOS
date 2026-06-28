import SwiftUI
import UIKit

// Flattened story image awaiting the audience sheet (used by both the photo editor + text composer).
struct StoryShareData: Identifiable { let id = UUID(); let data: Data }

// "Share Story" audience sheet: choose who sees the story, then Post.
// Posting kicks off a BACKGROUND upload (StoriesService.postStoryBackground) and pops to chat.
struct ShareStorySheet: View {
    let image: Data
    var onPosted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var mode = 0          // 0 = contacts, 1 = except, 2 = only
    @State private var excluded = Set<String>()
    @State private var included = Set<String>()
    @State private var showExclude = false
    @State private var showInclude = false
    private var me: String { AuthService.shared.uid ?? "" }

    struct AudienceContact: Identifiable { let id: String; let name: String; let photo: String? }
    private var contacts: [AudienceContact] {
        repo.conversations.filter { !$0.isGroup }.compactMap {
            let u = $0.otherUid(me)
            return u.isEmpty ? nil : AudienceContact(id: u, name: $0.displayName(me), photo: $0.displayPhoto(me))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                                .frame(width: 40, height: 40).background(Color(.secondarySystemGroupedBackground), in: Circle())
                        }
                        Spacer(); Text("Share Story").font(.headline); Spacer()
                        Color.clear.frame(width: 40, height: 40)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)

                    VStack(spacing: 0) {
                        optionRow(0, "person.fill", "My contacts", nil)
                        Divider().padding(.leading, 60)
                        optionRow(1, "person.fill.xmark", "My contacts except", "\(excluded.count) excluded")
                        Divider().padding(.leading, 60)
                        optionRow(2, "person.crop.circle.badge.checkmark", "Only share with", "\(included.count) included")
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(16)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: mode)

                    Spacer()

                    Button { post() } label: {
                        Text("Post Story").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(.blue, in: Capsule())
                    }
                    .buttonStyle(StoryPressStyle())
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            .sheet(isPresented: $showExclude) { AudiencePicker(title: "Exclude", contacts: contacts, selected: $excluded) }
            .sheet(isPresented: $showInclude) { AudiencePicker(title: "Only share with", contacts: contacts, selected: $included) }
        }
    }

    private func optionRow(_ m: Int, _ icon: String, _ title: String, _ subtitle: String?) -> some View {
        Button {
            mode = m
            if m == 1 { showExclude = true }
            if m == 2 { showInclude = true }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.primary)
                    .frame(width: 34, height: 34).background(Color.primary.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text("\(subtitle) · Edit").font(.footnote).foregroundStyle(.green) }
                }
                Spacer()
                if mode == m {
                    Image(systemName: "checkmark").foregroundStyle(.green).fontWeight(.semibold)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private func post() {
        // "Only share with" + nobody selected would post to NO audience — block it (I6).
        if mode == 2 && included.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return   // stay on the sheet so the user can pick someone
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        StoriesService.shared.postStoryBackground(
            image: image,
            excluded: mode == 1 ? excluded : [],
            included: mode == 2 ? included : []
        )
        onPosted()   // dismisses the editor -> back to chat; upload runs in the background
    }
}

// Multi-select contact list for the except/only audience lists.
struct AudiencePicker: View {
    let title: String
    let contacts: [ShareStorySheet.AudienceContact]
    @Binding var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if contacts.isEmpty {
                    ContentUnavailableView("No contacts", systemImage: "person.2",
                                           description: Text("Start a chat to build your contact list."))
                }
                ForEach(contacts) { c in
                    Button {
                        if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: c.name, photoUrl: c.photo, size: 36)
                            Text(c.name).foregroundStyle(.primary)
                            Spacer()
                            if selected.contains(c.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
        }
    }
}
