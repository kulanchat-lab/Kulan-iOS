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
    @State private var sendError: String?
    @State private var showAttachMenu = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var recorder = AudioRecorder()
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismiss) private var dismiss

    private var me: String { AuthService.shared.uid ?? "" }
    private var dark: Bool { scheme == .dark }

    init(cid: String, title: String, photoUrl: String?) {
        self.cid = cid
        self.title = title
        self.photoUrl = photoUrl
        _repo = State(initialValue: ThreadRepository(cid: cid))
    }

    var body: some View {
        VStack(spacing: 0) {
        chatHeader
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
            pinnedBar(proxy)
            ScrollView {
                LazyVStack(spacing: 0) {
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
                            onReact: { emoji in Task { await ChatService.setReaction(cid: cid, messageId: msg.id, emoji: emoji) } },
                            onPin: { m in Task { await ChatService.setPinnedMessage(cid, m.id) } },
                            otherLastRead: repo.otherLastReadMillis
                        )
                        .padding(.top, topGap(at: index))   // tight when grouped, wider on sender change
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)   // drag the messages down -> keyboard follows
            // Tap anywhere in the message area to close the keyboard (taps on
            // image bubbles still open the viewer — simultaneous, not consumed).
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
            .onChange(of: repo.messages.count) { _, _ in
                if let last = repo.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                Task { await ChatService.markRead(cid) }
            }
            }
        }
        if repo.iBlocked { blockedBar } else { composerArea }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background(SwipeBackEnabler())   // header is in the body -> slides 1:1; keep swipe-back
        .alert("Message not sent", isPresented: Binding(get: { sendError != nil },
                                                        set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sendError ?? "") }
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

    private func shouldShowDate(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(repo.messages[index - 1].createdAt,
                                        inSameDayAs: repo.messages[index].createdAt)
    }

    // Grouping: tight (3pt) when the previous message is from the same sender,
    // standard (14pt) on a sender change. The date separator carries its own gap.
    private func topGap(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if shouldShowDate(at: index) { return 0 }
        return repo.messages[index - 1].authorId == repo.messages[index].authorId ? 3 : 14
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // Liquid-Glass pinned-message bar below the nav (tap to scroll to it; pin.slash to unpin).
    @ViewBuilder private func pinnedBar(_ proxy: ScrollViewProxy) -> some View {
        if !repo.pinnedMessageId.isEmpty {
            let msg = repo.messages.first { $0.id == repo.pinnedMessageId }
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pinned Message").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    Text(msg.map { $0.isImage ? "📷 Photo" : ($0.isAudio ? "🎤 Voice message" : $0.text) } ?? "Tap to view")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { Task { await ChatService.setPinnedMessage(cid, nil) } } label: {
                    Image(systemName: "pin.slash").font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
            .padding(.horizontal, 12).padding(.top, 8)
            .contentShape(Rectangle())
            .onTapGesture { if let id = msg?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
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

    private var otherUid: String {
        cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
    }

    // Header lives in the BODY (not the toolbar) so it slides 1:1 with the messages
    // during the edge swipe-back — exactly like Signal. Back chevron + avatar + name
    // on the left, voice-call button on the right.
    private var chatHeader: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
            NavigationLink {
                ContactInfoView(cid: cid, name: title, photoUrl: photoUrl)
            } label: {
                HStack(spacing: 10) {
                    AvatarView(name: title, photoUrl: photoUrl, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        if let sub = presenceSubtitle {
                            Text(sub).font(.system(size: 12))
                                .foregroundStyle(repo.otherTyping ? Color.accentColor : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Button { CallService.shared.startCall(to: otherUid, name: title, photo: photoUrl) } label: {
                Image(systemName: "phone.fill").font(.system(size: 17)).foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(Theme.bg(dark))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func send() {
        let text = input
        input = ""
        let reply = replyingTo.map {
            ReplyRef(id: $0.id, authorId: $0.authorId,
                     text: $0.isImage ? "📷 Photo" : ($0.isAudio ? "🎤 Voice message" : $0.text))
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

    // The reply preview now nests INSIDE the input capsule (see inputRow).
    private var composerArea: some View { composer }

    // Active-reply preview row, shown inside the input capsule above the text field.
    private func replyPreviewRow(_ r: Message) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.6)).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reply to \(r.authorId == me ? "yourself" : title)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                Text(r.isImage ? "📷 Photo" : (r.isAudio ? "🎤 Voice message" : r.text))
                    .font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { replyingTo = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 8).padding(.bottom, 4)
    }

    // Subtle neutral fill (no glass, no shadow) — the iMessage field tint.
    private var fieldFill: Color { dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xEEEEF2) }

    private var composer: some View {
        Group {
            if recorder.isRecording { recordingBar } else { inputRow }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .confirmationDialog("Send a photo", isPresented: $showAttachMenu, titleVisibility: .visible) {
            Button("Take Photo") { showCamera = true }
            Button("Photo Library") { showLibrary = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in Task { await sendCaptured(data) } }
                .ignoresSafeArea()
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Far-left circular "+" — Take Photo (camera) or Photo Library.
            Button { showAttachMenu = true } label: {
                Image(systemName: sendingPhoto ? "ellipsis" : "plus")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .liquidGlass(Circle())   // real iOS 26 Liquid Glass
            }
            .tint(.primary)

            // Input container: optional reply preview + divider, then the text row.
            VStack(spacing: 0) {
                if let r = replyingTo {
                    replyPreviewRow(r)
                    Divider().padding(.horizontal, 12)
                }
                // Text row: send arrow when typing, mic to record a voice note when empty.
                HStack(alignment: .bottom, spacing: 4) {
                    TextField("Message", text: $input, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($inputFocused)
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
                        HStack(spacing: 14) {
                            Button { showCamera = true } label: {
                                Image(systemName: "camera").font(.system(size: 19)).foregroundStyle(.secondary)
                            }
                            Button { recorder.requestAndStart() } label: {
                                Image(systemName: "mic").font(.system(size: 19)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 7)
                    }
                }
            }
            .frame(minHeight: 36)
            .liquidGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))   // real iOS 26 Liquid Glass
        }
    }

    // Shown while recording a voice note: cancel · red dot + timer · send.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button { recorder.cancel() } label: {
                Image(systemName: "trash").font(.system(size: 18)).foregroundStyle(.red)
                    .frame(width: 36, height: 36)
            }
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(timeString(recorder.elapsed)).font(.subheadline.monospacedDigit())
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .liquidGlass(Capsule())
            Button { Task { await stopAndSendAudio() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    .foregroundStyle(Theme.accent(dark))
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func stopAndSendAudio() async {
        guard let (data, dur) = recorder.finish() else { return }
        try? await ChatService.sendAudio(cid: cid, data: data, duration: dur)
    }

    private func sendCaptured(_ data: Data) async {
        sendingPhoto = true
        try? await ChatService.sendImage(cid: cid, data: data)
        sendingPhoto = false
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
    var onReact: (String?) -> Void = { _ in }
    var onPin: (Message) -> Void = { _ in }
    var otherLastRead: Double = 0

    @State private var dragX: CGFloat = 0
    @State private var showDelete = false

    private static let reactionChoices = ["❤️", "👍", "😂", "😮", "😢", "🙏"]
    private var myUid: String { AuthService.shared.uid ?? "" }
    private var myReaction: String? { message.reactions[myUid] }
    private var reactionEmojis: [String] { Array(Set(message.reactions.values)).sorted() }

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

    // Bubbles cap at 72% of screen width and wrap; the right (sent) / left (received)
    // edge stays a clean, uniform line regardless of length.
    private var maxBubbleWidth: CGFloat { UIScreen.main.bounds.width * 0.72 }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 0) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                content
                    .contextMenu {
                        ForEach(Self.reactionChoices, id: \.self) { emoji in
                            Button { onReact(myReaction == emoji ? nil : emoji) } label: {
                                Text(myReaction == emoji ? "\(emoji)  ✓ Remove" : emoji)
                            }
                        }
                        Divider()
                        Button { onReply(message) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        Button { onPin(message) } label: { Label("Pin", systemImage: "pin") }
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
                if !reactionEmojis.isEmpty {
                    Text(reactionEmojis.joined())
                        .font(.system(size: 13))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.received(dark), in: Capsule())
                        .overlay(Capsule().stroke(dark ? Color(hex: 0x121214) : .white, lineWidth: 2))
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: isMe ? .trailing : .leading)
            if !isMe { Spacer(minLength: 0) }
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
        if message.isAudio {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                VoiceMessageView(message: message, cid: cid, isMe: isMe, dark: dark)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(isMe ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if message.isImage, let url = message.imageUrl {
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
            let fg = isMe ? Theme.onAccent(dark) : (dark ? Color.white : .black)
            HStack(spacing: 7) {
                // Left accent line signalling a quoted reply.
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fg.opacity(0.7))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nameFor(reply.authorId)).font(.caption.weight(.semibold))
                        .foregroundStyle(fg.opacity(0.9))
                    Text(reply.text.isEmpty ? "Message" : reply.text).font(.caption).lineLimit(1)
                        .foregroundStyle(fg.opacity(0.75))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isMe ? Color.white.opacity(0.15) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
