import SwiftUI

// Native TabView keeps both tabs permanently mounted -> the header avatar never
// unmounts/blinks on tab switch (the RN bug, solved structurally).
struct MainShell: View {
    var body: some View {
        TabView {
            ChatsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.fill") }
            CallsView()
                .tabItem { Label("Calls", systemImage: "phone.fill") }
        }
    }
}

struct CallsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Calls coming soon").font(.headline)
            Text("Voice and video will live here.").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct ChatsView: View {
    private var repo = ConversationsRepository.shared
    @Environment(\.colorScheme) private var scheme
    @State private var showNew = false

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }

    private var visible: [Conversation] {
        repo.conversations
            .filter { !$0.isCleared(me) && !$0.isArchived(me) }
            .sorted {
                if $0.isPinned(me) != $1.isPinned(me) { return $0.isPinned(me) }
                return $0.updatedAtMillis > $1.updatedAtMillis
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visible.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left",
                                           description: Text("Tap the compose button to start one."))
                } else {
                    List(visible) { conv in
                        NavigationLink(value: conv) {
                            ChatRow(conv: conv, me: me, dark: dark)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .navigationDestination(for: Conversation.self) { conv in
                ThreadView(cid: conv.id, title: conv.name(for: me),
                           photoUrl: conv.photoUrl(for: me))
            }
            .sheet(isPresented: $showNew) { NewChatView() }
        }
        .onAppear { repo.start() }
    }
}

struct ChatRow: View {
    let conv: Conversation
    let me: String
    let dark: Bool

    private var preview: String {
        let decoded = Crypto.shared.decrypt(conv.lastMessageCipher, cid: conv.id)
        return decoded.isEmpty ? "Say hello 👋" : decoded
    }
    private var unread: Int { conv.unread(me) }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.name(for: me))
                    .font(.system(size: 17, weight: unread > 0 ? .semibold : .regular))
                    .lineLimit(1)
                Text(preview)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if unread > 0 {
                Text("\(min(unread, 99))")
                    .font(.caption2.bold()).foregroundColor(Theme.onAccent(dark))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent(dark)).clipShape(Capsule())
            }
        }
        .padding(.vertical, 6)
    }
}
