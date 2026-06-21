import SwiftUI
import PhotosUI
import UIKit

struct ThreadView: View {
    let cid: String
    let title: String
    let photoUrl: String?

    @State private var repo: ThreadRepository
    @State private var input = ""
    @State private var replyingTo: Message?
    @State private var photoItem: PhotosPickerItem?
    @State private var sendingPhoto = false
    @State private var typingSent = false
    @State private var viewerImage: Message?
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
                        MessageBubble(
                            message: msg, isMe: msg.authorId == me, dark: dark, cid: cid,
                            nameFor: { $0 == me ? "You" : title },
                            onReply: { replyingTo = $0 },
                            onDelete: { m in Task { await ChatService.deleteMessage(cid: cid, messageId: m.id) } },
                            onTapImage: { viewerImage = $0 },
                            otherLastRead: repo.otherLastReadMillis
                        )
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
                Task { await ChatService.markRead(cid) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavigationLink {
                    ContactInfoView(cid: cid, name: title, photoUrl: photoUrl)
                } label: {
                    HStack(spacing: 8) {
                        AvatarView(name: title, photoUrl: photoUrl, size: 30)
                        VStack(spacing: 0) {
                            Text(title).font(.headline).foregroundStyle(.primary)
                            if let sub = presenceSubtitle {
                                Text(sub).font(.caption2)
                                    .foregroundStyle(repo.otherTyping ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composerArea }
        .fullScreenCover(item: $viewerImage) { msg in
            ImageViewerView(message: msg, cid: cid)
        }
        .onAppear {
            repo.start()
            Task { await ChatService.resetUnread(cid); await ChatService.markRead(cid) }
        }
        .onDisappear {
            repo.stop()
            Task { await ChatService.setTyping(cid, false) }
        }
        .onChange(of: photoItem) { _, item in Task { await sendPicked(item) } }
    }

    private var hasText: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var presenceSubtitle: String? {
        if repo.otherTyping { return "typing…" }
        if repo.otherOnline { return "online" }
        if let la = repo.otherLastActive {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
            return "last seen " + f.localizedString(for: la, relativeTo: Date())
        }
        return nil
    }

    private func send() {
        let text = input
        input = ""
        let reply = replyingTo.map {
            ReplyRef(id: $0.id, authorId: $0.authorId, text: $0.isImage ? "📷 Photo" : $0.text)
        }
        replyingTo = nil
        typingSent = false
        Task {
            await ChatService.setTyping(cid, false)
            try? await ChatService.sendText(cid: cid, text: text, replyTo: reply)
        }
    }

    private func sendPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        sendingPhoto = true
        defer { sendingPhoto = false; photoItem = nil }
        if let data = try? await item.loadTransferable(type: Data.self) {
            try? await ChatService.sendImage(cid: cid, data: data)
        }
    }

    // Reply preview (if any) above the Liquid-Glass composer row.
    private var composerArea: some View {
        VStack(spacing: 6) {
            if let r = replyingTo {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Reply to \(r.authorId == me ? "yourself" : title)")
                            .font(.caption.bold()).foregroundStyle(.tint)
                        Text(r.isImage ? "📷 Photo" : r.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
            }
            composer
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Group {
                    if sendingPhoto { ProgressView() }
                    else { Image(systemName: "paperclip").font(.system(size: 18)).foregroundStyle(.primary) }
                }
                .frame(width: 40, height: 40)
            }
            .liquidGlass(Circle())

            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.leading, 16)
                    .padding(.vertical, 10)
                    .onChange(of: input) { _, v in
                        let now = !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if now != typingSent {
                            typingSent = now
                            Task { await ChatService.setTyping(cid, now) }
                        }
                    }
                Image(systemName: "face.smiling")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 13)
                    .padding(.bottom, 9)
            }
            .frame(minHeight: 40)
            .liquidGlass(Capsule())

            Button { if hasText { send() } } label: {
                Image(systemName: hasText ? "arrow.up" : "mic.fill")
                    .font(.system(size: 17, weight: hasText ? .bold : .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
            }
            .liquidGlass(Circle())
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

struct MessageBubble: View {
    let message: Message
    let isMe: Bool
    let dark: Bool
    let cid: String
    var nameFor: (String) -> String = { _ in "" }
    var onReply: (Message) -> Void = { _ in }
    var onDelete: (Message) -> Void = { _ in }
    var onTapImage: (Message) -> Void = { _ in }
    var otherLastRead: Double = 0

    @State private var dragX: CGFloat = 0

    private var isRead: Bool {
        message.createdAt.timeIntervalSince1970 * 1000 <= otherLastRead
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if isMe { Spacer(minLength: 50) }
            content
                .contextMenu {
                    Button { onReply(message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    if !message.isImage && !message.text.isEmpty {
                        Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                    if isMe {
                        Button(role: .destructive) { onDelete(message) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            if isMe {
                Image(systemName: isRead ? "checkmark.circle.fill" : "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isRead ? Color.blue : Color.secondary)
                    .padding(.bottom, 2)
            }
            if !isMe { Spacer(minLength: 50) }
        }
        // Telegram-style swipe-to-reply: drag the bubble left past a threshold.
        .overlay(alignment: .trailing) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .opacity(Double(min(abs(min(dragX, 0)) / 50, 1)))
                .padding(.trailing, 6)
        }
        .offset(x: dragX)
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { v in if v.translation.width < 0 { dragX = max(v.translation.width, -70) } }
                .onEnded { _ in
                    if dragX < -50 {
                        onReply(message)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragX = 0 }
                }
        )
    }

    @ViewBuilder private var content: some View {
        if message.isImage, let url = message.imageUrl {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                SecureImageView(imageUrl: url, enc: message.enc, cid: cid)
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture { onTapImage(message) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                Text(message.text)
                    .font(.body)
                    .foregroundColor(isMe ? Theme.onAccent(dark) : (dark ? .white : .black))
            }
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(isMe ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    @ViewBuilder private var replyQuote: some View {
        if let reply = message.replyTo {
            VStack(alignment: .leading, spacing: 1) {
                Text(nameFor(reply.authorId)).font(.caption.bold())
                    .foregroundStyle(isMe ? Theme.onAccent(dark).opacity(0.9) : .secondary)
                Text(reply.text.isEmpty ? "Message" : reply.text).font(.caption).lineLimit(1)
                    .foregroundStyle(isMe ? Theme.onAccent(dark).opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isMe ? Color.white.opacity(0.18) : Theme.secondary.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
