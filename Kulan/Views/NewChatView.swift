import SwiftUI

struct NewChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var results: [UserProfile] = []
    @State private var busy = false
    @State private var error: String?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(results) { user in
                    Button {
                        Task { await start(user) }
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: user.name.isEmpty ? user.handle : user.name,
                                       photoUrl: user.photoUrl, size: 44)
                            VStack(alignment: .leading) {
                                Text(user.name.isEmpty ? user.handle : user.name)
                                    .foregroundStyle(.primary)
                                Text("@\(user.handle)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if results.isEmpty && !query.isEmpty && !busy {
                    Text("No one found for “\(query)”").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search username")
            .onChange(of: query) { _, q in
                Task {
                    let r = await ChatService.searchUsers(prefix: q)
                    await MainActor.run { results = r }
                }
            }
            .overlay { if busy { ProgressView() } }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
    }

    private func start(_ user: UserProfile) async {
        busy = true; error = nil
        do {
            _ = try await ChatService.openConversation(other: user)
            // The new conversation now appears in the live chat list; close the sheet.
            dismiss()
        } catch {
            self.error = "Could not start chat: \(error.localizedDescription)"
        }
        busy = false
    }
}
