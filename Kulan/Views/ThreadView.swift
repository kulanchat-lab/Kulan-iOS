import SwiftUI

struct ThreadView: View {
    let cid: String
    let title: String
    let photoUrl: String?

    @State private var repo: ThreadRepository
    @State private var input = ""
    @Environment(\.colorScheme) private var scheme

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }

    init(cid: String, title: String, photoUrl: String?) {
        self.cid = cid
        self.title = title
        self.photoUrl = photoUrl
        _repo = State(initialValue: ThreadRepository(cid: cid))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(repo.messages) { msg in
                        MessageBubble(message: msg, isMe: msg.authorId == me, dark: dark)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: repo.messages.count) { _, _ in
                if let last = repo.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) { composer }
        .onAppear {
            repo.start()
            Task { await ChatService.resetUnread(cid) }
        }
        .onDisappear { repo.stop() }
    }

    private var hasText: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = input
        input = ""
        Task { try? await ChatService.sendText(cid: cid, text: text) }
    }

    // Native iMessage-style composer: a left "+" circle, a unified soft-gray
    // capsule holding the text field + inline action glyphs, on a translucent base.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(Theme.received(dark), in: Circle())
            }

            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.leading, 14)
                    .padding(.vertical, 9)

                if hasText {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.onAccent(dark))
                            .frame(width: 30, height: 30)
                            .background(Theme.accent(dark), in: Circle())
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 3)
                } else {
                    HStack(spacing: 14) {
                        Image(systemName: "face.smiling")
                        Image(systemName: "camera")
                        Image(systemName: "mic")
                    }
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
                    .padding(.bottom, 9)
                }
            }
            .background(Theme.received(dark), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

struct MessageBubble: View {
    let message: Message
    let isMe: Bool
    let dark: Bool

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 4) {
                if let reply = message.replyTo {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reply.text.isEmpty ? "Message" : reply.text)
                            .font(.caption).lineLimit(1)
                            .foregroundStyle(isMe ? Theme.onAccent(dark).opacity(0.85) : .secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((isMe ? Color.white.opacity(0.18) : Theme.secondary.opacity(0.18)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if message.isImage {
                    Text("📷 Photo")
                        .font(.body)
                        .foregroundColor(isMe ? Theme.onAccent(dark) : Theme.accent(dark))
                } else {
                    Text(message.text)
                        .font(.body)
                        .foregroundColor(isMe ? Theme.onAccent(dark) : (dark ? .white : .black))
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(isMe ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            if !isMe { Spacer(minLength: 50) }
        }
    }
}
