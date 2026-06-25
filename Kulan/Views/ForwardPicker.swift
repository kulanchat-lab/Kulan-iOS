import SwiftUI

// Forward a message to one or more chats. Pick chats (multi-select), tap Send, and the
// message is re-sent into each via ChatService.forwardMessage (E2EE re-encrypts media
// for the target chat). Excludes the source chat. Real send pipeline — no fakes.
struct ForwardPicker: View {
    let message: Message
    let sourceCid: String

    @Environment(\.dismiss) private var dismiss
    @State private var repo = ConversationsRepository.shared
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var sending = false
    private var me: String { AuthService.shared.uid ?? "" }

    private var people: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = repo.conversations.filter { !$0.otherUid(me).isEmpty && $0.id != sourceCid }
        return (q.isEmpty ? list : list.filter { $0.name(for: me).lowercased().contains(q) })
            .sorted { $0.displayUpdatedAt(me) > $1.displayUpdatedAt(me) }
    }

    private var snippet: String {
        if message.isImage { return "📷 Photo" }
        if message.isAudio { return "🎤 Voice message" }
        return message.text
    }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    ContentUnavailableView("No other chats", systemImage: "paperplane",
                                           description: Text("Start another chat to forward into it."))
                } else {
                    List {
                        Section {
                            ForEach(people) { c in
                                Button { toggle(c.id) } label: {
                                    HStack(spacing: 12) {
                                        AvatarView(name: c.name(for: me), photoUrl: c.photoUrl(for: me), size: 44)
                                        Text(c.name(for: me))
                                            .font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundStyle(selected.contains(c.id) ? Color.accentColor : Color.secondary)
                                    }
                                }
                                .listRowSeparator(.hidden)
                            }
                        } header: {
                            Text("Forwarding: \(snippet)").textCase(nil)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") }.tint(.primary) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { Task { await sendAll() } }
                        .disabled(selected.isEmpty || sending)
                        .fontWeight(.semibold)
                }
            }
            .overlay {
                if sending {
                    ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func sendAll() async {
        sending = true
        for cid in selected {
            try? await ChatService.forwardMessage(message, from: sourceCid, to: cid)
        }
        sending = false
        dismiss()
    }
}
