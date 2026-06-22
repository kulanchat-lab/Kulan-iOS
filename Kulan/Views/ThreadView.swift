import SwiftUI
import PhotosUI
import UIKit
import Combine

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
    @State private var keyboardHeight: CGFloat = 0
    @State private var sendError: String?
    @Environment(\.colorScheme) private var scheme

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }

    // Real bottom safe-area (home indicator) so the composer pins exactly to the
    // keyboard top with no gap — read from the key window, not a GeometryReader.
    private var bottomSafeInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.safeAreaInsets.bottom ?? 0
    }

    init(cid: String, title: String, photoUrl: String?) {
        self.cid = cid
        self.title = title
        self.photoUrl = photoUrl
        _repo = State(initialValue: ThreadRepository(cid: cid))
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(repo.messages.enumerated()), id: \.element.id) { index, msg in
                        if shouldShowDate(at: index) {
                            Text(dayLabel(msg.createdAt))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
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
            .onChange(of: keyboardHeight) { _, _ in
                if let last = repo.messages.last {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        if repo.iBlocked { blockedBar } else { composerArea }
        }
        .padding(.bottom, max(0, keyboardHeight - bottomSafeInset))
        .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { headerToolbar }
        .alert("Message not sent", isPresented: Binding(get: { sendError != nil },
                                                        set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sendError ?? "") }
        .fullScreenCover(item: $viewerImage) { msg in
            ImageViewerView(message: msg, cid: cid)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            if let f = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = max(0, UIScreen.main.bounds.height - f.minY)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
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

    private func shouldShowDate(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(repo.messages[index - 1].createdAt,
                                        inSameDayAs: repo.messages[index].createdAt)
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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

    // Signal-style header: a flat title view INSIDE the native nav bar (next to the
    // system back button) so we keep the smooth push animation and edge swipe-back.
    // On iOS 26 the toolbar would wrap it in a Liquid-Glass pill, so we strip that
    // with .sharedBackgroundVisibility(.hidden) — the official opt-out.
    @ViewBuilder private var headerLabel: some View {
        NavigationLink {
            ContactInfoView(cid: cid, name: title, photoUrl: photoUrl)
        } label: {
            HStack(spacing: 8) {
                AvatarView(name: title, photoUrl: photoUrl, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                        .lineLimit(1)
                    if let sub = presenceSubtitle {
                        Text(sub).font(.caption2)
                            .foregroundStyle(repo.otherTyping ? Color.accentColor : Color.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .fixedSize()   // keep the name's natural width — nav bar was crushing it to 0
        }
        .buttonStyle(.plain)
    }

    // .principal (the title slot) so iOS animates the avatar+name 1:1 with the
    // body during the interactive swipe-back — leading/trailing bar items don't
    // ride that transition and would freeze, then snap.
    @ToolbarContentBuilder private var headerToolbar: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .principal) { headerLabel }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { headerLabel }
        }
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
            do {
                try await ChatService.sendText(cid: cid, text: text, replyTo: reply)
            } catch {
                // Don't silently drop the message — restore it and tell the user why.
                await MainActor.run {
                    input = text
                    if error is MissingRecipientKeyError {
                        sendError = "\(title) hasn't set up encryption yet (they need to open Kulan once). Your message wasn't sent."
                    } else {
                        sendError = "Couldn't send your message. \(error.localizedDescription)"
                    }
                }
            }
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

    // When I've blocked this contact, the composer is replaced by an unblock bar —
    // you genuinely can't send while blocked (real enforcement, not cosmetic).
    private var blockedBar: some View {
        VStack(spacing: 6) {
            Text("You blocked \(title)").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Button("Unblock") { Task { await ChatService.setBlocked(cid, false) } }
                .font(.subheadline.weight(.semibold))
                .tint(.red)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.bar)
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
                .background(fieldFill, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 12)
            }
            composer
        }
    }

    // Subtle neutral fill (no glass, no shadow) — the iMessage field tint.
    private var fieldFill: Color { dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xEFEFF4) }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Far-left circular "+" — attach a photo.
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: sendingPhoto ? "ellipsis" : "plus")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(fieldFill, in: Circle())
            }

            // Text capsule with the send arrow embedded on its inside-right edge.
            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.leading, 14)
                    .padding(.vertical, 7)
                    .onChange(of: input) { _, v in
                        let now = !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if now != typingSent {
                            typingSent = now
                            Task { await ChatService.setTyping(cid, now) }
                        }
                    }
                if hasText {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.accent(dark))
                    }
                    .padding(.trailing, 3)
                    .padding(.bottom, 2)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
            }
            .frame(minHeight: 34)
            .background(fieldFill, in: Capsule())
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
    @State private var showDelete = false

    private var isRead: Bool {
        message.createdAt.timeIntervalSince1970 * 1000 <= otherLastRead
    }

    private var timeString: String {
        message.createdAt.formatted(date: .omitted, time: .shortened)
    }

    // Time + read-check, shown INSIDE the bubble bottom-right (Signal style).
    @ViewBuilder private var metaRow: some View {
        HStack(spacing: 3) {
            Text(timeString).font(.system(size: 10))
            if isMe {
                Image(systemName: isRead ? "checkmark.circle.fill" : "checkmark")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(isMe ? Theme.onAccent(dark).opacity(0.7) : Color.secondary)
    }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 50) }
            content
                .contextMenu {
                    Button { onReply(message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    if !message.isImage && !message.text.isEmpty {
                        Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                    if isMe {
                        Button(role: .destructive) { showDelete = true } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .confirmationDialog("Delete this message?", isPresented: $showDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { onDelete(message) }
                    Button("Cancel", role: .cancel) {}
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
                    .overlay(alignment: .bottomTrailing) {
                        metaRow
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(7)
                    }
                    .onTapGesture { onTapImage(message) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                // Text + time laid out in a real HStack so the time can never
                // overlap the words. Short msgs => same line; long msgs => the
                // text wraps and the time stays at the bottom-right corner.
                HStack(alignment: .bottom, spacing: 6) {
                    Text(message.text)
                        .font(.body)
                        .foregroundColor(isMe ? Theme.onAccent(dark) : (dark ? .white : .black))
                    metaRow.padding(.bottom, 1)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
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
