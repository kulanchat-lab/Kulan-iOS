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
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showVideoSoon = false
    // Hold-to-record voice gesture state (WhatsApp/Telegram-style).
    @State private var recordLocked = false        // recording continues after finger lifts
    @State private var recordDrag: CGSize = .zero   // live finger translation while holding
    @State private var recordCancelArmed = false    // dragged left past the cancel threshold
    @State private var holdStarted = false          // guards a single start per hold
    @State private var recorder = AudioRecorder()
    @State private var highlightId: String?
    @State private var isAtBottom = true
    @State private var newWhileAway = 0
    @State private var unreadOnOpen = 0
    @State private var firstUnreadId: String?
    @State private var didAnchorUnread = false
    @State private var menuTarget: Message?       // long-press reaction/actions menu
    @State private var morePickerTarget: Message? // any-emoji picker
    @State private var reactorsTarget: Message?   // "who reacted" sheet
    @State private var pendingDelete: Message?
    @State private var editTarget: Message?       // edit-message sheet
    @State private var forwardTarget: Message?    // forward-to-chat picker
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("typingIndicators") private var typingPref = true
    @AppStorage("shareLastSeen") private var lastSeenPref = true

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
            VStack(spacing: 0) {
            pinnedBar(proxy)
            ScrollView {
                messageList(proxy)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)   // drag the messages down -> keyboard follows
            // Tap anywhere in the message area to close the keyboard (taps on
            // image bubbles still open the viewer — simultaneous, not consumed).
            .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
            .onChange(of: repo.items.count) { old, new in
                guard new > old else { return }
                let mine = repo.items.last?.authorId == me
                // While we still need to land on the unread divider, let anchorUnread
                // position the list (don't fight it by jumping to the bottom).
                if !didAnchorUnread && unreadOnOpen > 0 {
                    // no-op: anchorUnread handles initial positioning
                } else if isAtBottom || mine {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                } else {
                    newWhileAway += 1
                }
                if !repo.iBlocked { Task { await ChatService.markRead(cid) } }   // don't leak reads to a blocked user
            }
            .onChange(of: repo.messages.count) { _, _ in anchorUnread(proxy) }
            .onChange(of: unreadOnOpen) { _, _ in anchorUnread(proxy) }
            .onChange(of: repo.otherTyping) { _, t in
                if t && isAtBottom { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("BOTTOM", anchor: .bottom) } }
            }
            // Floating jump-to-bottom button (our design) — appears when scrolled up,
            // with a count of messages that arrived while away.
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .liquidGlass(Circle())
                            .overlay(alignment: .top) {
                                if newWhileAway > 0 {
                                    Text("\(newWhileAway)").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor, in: Capsule())
                                        .offset(y: -9)
                                }
                            }
                    }
                    .padding(.trailing, 16).padding(.bottom, 10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            // Float the composer OVER the messages (iOS 26 native via safeAreaBar):
            // the glass dims/blurs the messages scrolling under it like iMessage;
            // the scroll content auto-insets so the last message never hides.
            .floatingBottomBar {
                if repo.iBlocked { blockedBar } else { composerArea }
            }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        // Native nav bar = real iOS 26 Liquid Glass + the genuine edge-swipe-back, exactly
        // like the Chats list header. Avatar/name/call buttons live in the toolbar.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { chatToolbar }
        .alert("Video calls", isPresented: $showVideoSoon) {
            Button("OK", role: .cancel) {}
        } message: { Text("Video calling is coming soon.") }
        .alert("Message not sent", isPresented: Binding(get: { sendError != nil },
                                                        set: { if !$0 { sendError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(sendError ?? "") }
        .fullScreenCover(item: $viewerImage) { msg in
            ImageViewerView(message: msg, cid: cid)
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in Task { await sendCaptured(data) } }
                .ignoresSafeArea()
        }
        .overlay {
            if let m = menuTarget {
                ReactionMenuOverlay(
                    message: m, cid: cid, dark: dark, isMe: m.authorId == me, myReaction: m.reactions[me],
                    onPick: { emoji in react(m, emoji); dismissMenu() },
                    onMore: { dismissMenu(); morePickerTarget = m },
                    onReply: { replyingTo = m; dismissMenu() },
                    onForward: { dismissMenu(); forwardTarget = m },
                    onPin: { Task { await ChatService.setPinnedMessage(cid, m.id) }; dismissMenu() },
                    onCopy: { dismissMenu() },
                    onEdit: { dismissMenu(); editTarget = m },
                    onDelete: { dismissMenu(); pendingDelete = m },
                    onDismiss: { dismissMenu() }
                )
                .transition(.opacity)
            }
        }
        .sheet(item: $morePickerTarget) { m in EmojiMorePicker { emoji in react(m, emoji) } }
        .sheet(item: $reactorsTarget) { m in
            ReactorsSheet(reactions: m.reactions, nameFor: { $0 == me ? "You" : title })
        }
        .sheet(item: $editTarget) { m in
            EditMessageSheet(original: m.text) { newText in
                Task { try? await ChatService.editMessage(cid: cid, messageId: m.id, newText: newText) }
            }
        }
        .sheet(item: $forwardTarget) { m in
            ForwardPicker(message: m, sourceCid: cid)
        }
        .confirmationDialog("Delete this message?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let m = pendingDelete { Task { await ChatService.deleteMessage(cid: cid, messageId: m.id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        .onAppear {
            repo.start()
            AppRouter.shared.activeChatId = cid          // suppress this chat's own banners
            NotificationCleaner.clear(cid: cid)          // clear its notifications + fix the badge
            Task {
                let n = await ChatService.myUnread(cid)   // capture BEFORE reset, to anchor the divider
                await MainActor.run { unreadOnOpen = n }
                await ChatService.resetUnread(cid)
                if !repo.iBlocked { await ChatService.markRead(cid) }
            }
        }
        .onDisappear {
            repo.stop()
            AppRouter.shared.activeChatId = nil
            Task { await ChatService.setTyping(cid, false) }
        }
        .onChange(of: photoItem) { _, item in Task { await sendPicked(item) } }
    }

    private var hasText: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func shouldShowDate(at index: Int) -> Bool {
        let items = repo.items
        guard index > 0, index < items.count else { return true }
        return !Calendar.current.isDate(items[index - 1].createdAt, inSameDayAs: items[index].createdAt)
    }

    // Grouping: tight (2pt) inside a same-sender cluster, standard (14pt) on a new
    // cluster. The date separator carries its own gap.
    private func topGap(at index: Int) -> CGFloat {
        if shouldShowDate(at: index) { return 0 }
        return isFirstInCluster(at: index) ? 14 : 2
    }

    private static let clusterGap: TimeInterval = 300   // 5 min breaks a cluster

    // A new cluster starts on a date change, a sender change, or a >5min time gap.
    private func isFirstInCluster(at index: Int) -> Bool {
        let items = repo.items
        guard index > 0, index < items.count else { return true }
        if shouldShowDate(at: index) { return true }
        if items[index - 1].authorId != items[index].authorId { return true }
        return items[index].createdAt.timeIntervalSince(items[index - 1].createdAt) > Self.clusterGap
    }

    // A cluster ends at the last message, a sender change, a date change, or a >5min gap.
    private func isLastInCluster(at index: Int) -> Bool {
        let items = repo.items
        guard index >= 0, index < items.count - 1 else { return true }
        let next = items[index + 1], cur = items[index]
        if !Calendar.current.isDate(cur.createdAt, inSameDayAs: next.createdAt) { return true }
        if next.authorId != cur.authorId { return true }
        return next.createdAt.timeIntervalSince(cur.createdAt) > Self.clusterGap
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
        if repo.iBlocked { return nil }   // blocked: don't reveal their typing/online/last-seen
        if typingPref && repo.otherTyping { return "typing…" }   // reciprocal: only if I share typing
        if lastSeenPref {                                        // reciprocal: only if I share last-seen
            if repo.otherOnline { return "online" }
            if let la = repo.otherLastActive {
                let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
                return "last seen " + f.localizedString(for: la, relativeTo: Date())
            }
        }
        return nil
    }

    private var otherUid: String {
        cid.split(separator: "_").map(String.init).first { $0 != me } ?? ""
    }

    // Extracted from `body` so the type-checker can handle the screen (the inline ForEach
    // with all its closures was too complex as one expression after the header refactor).
    @ViewBuilder
    private func messageList(_ proxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 0) {
            // Scroll-to-top spinner: pages in older history, then restores the anchor.
            if repo.canLoadOlder {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .id("TOP")
                    .onAppear { loadOlderWithAnchor(proxy) }
            }
            ForEach(Array(repo.items.enumerated()), id: \.element.rowId) { index, msg in
                if shouldShowDate(at: index) {
                    Text(dayLabel(msg.createdAt))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                if msg.id == firstUnreadId { unreadDivider }
                if msg.isCall {
                    callRow(msg).padding(.top, 8).id(msg.id)
                } else {
                    MessageBubble(
                        message: msg, isMe: msg.authorId == me, dark: dark, cid: cid,
                        nameFor: { $0 == me ? "You" : title },
                        onReply: { replyingTo = $0 },
                        onDelete: { m in Task { await ChatService.deleteMessage(cid: cid, messageId: m.id) } },
                        onTapImage: { viewerImage = $0 },
                        onReact: { emoji in Task { await ChatService.setReaction(cid: cid, messageId: msg.id, emoji: emoji) } },
                        onPin: { m in Task { await ChatService.setPinnedMessage(cid, m.id) } },
                        onTapReactions: { reactorsTarget = msg },
                        onLongPress: { m in withAnimation(.easeOut(duration: 0.15)) { menuTarget = m } },
                        onResend: { m in resend(m) },
                        onJumpTo: { id in jump(to: id, proxy) },
                        isHighlighted: msg.id == highlightId,
                        isFirstInCluster: isFirstInCluster(at: index),
                        isLastInCluster: isLastInCluster(at: index),
                        otherLastRead: repo.otherLastReadMillis
                    )
                    .padding(.top, topGap(at: index))   // tight when grouped, wider on sender change
                    .id(msg.id)
                    .contextMenu { messageMenu(msg) }   // real native menu (like the chat list)
                }
            }
            if repo.otherTyping && !repo.iBlocked && typingPref { TypingBubble(dark: dark).padding(.top, 6).id("TYPING") }
            // Bottom sentinel: drives "am I at the bottom?" for the scroll button.
            Color.clear.frame(height: 1).id("BOTTOM")
                .onAppear { isAtBottom = true; newWhileAway = 0 }
                .onDisappear { isAtBottom = false }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Real native context menu (system blur/animation, like the chat list long-press).
    // Reactions sit in a native ControlGroup row at the top; then the standard actions.
    @ViewBuilder private func messageMenu(_ msg: Message) -> some View {
        ControlGroup {
            ForEach(["❤️", "👍", "😂", "😮", "😢", "🙏"], id: \.self) { e in
                Button(e) { react(msg, e) }
            }
        }
        Button { replyingTo = msg } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        if !msg.isCall {
            Button { forwardTarget = msg } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        }
        if !msg.isImage && !msg.text.isEmpty {
            Button { UIPasteboard.general.string = msg.text } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        Button { Task { await ChatService.setPinnedMessage(cid, msg.id) } } label: { Label("Pin", systemImage: "pin") }
        if msg.authorId == me && !msg.isImage && !msg.isAudio && !msg.isCall && msg.sendState == nil {
            Button { editTarget = msg } label: { Label("Edit", systemImage: "pencil") }
        }
        Button { morePickerTarget = msg } label: { Label("More reactions…", systemImage: "face.smiling") }
        if msg.authorId == me {
            Button(role: .destructive) { pendingDelete = msg } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // Native toolbar header (real Liquid Glass + native back/swipe), same approach as the
    // Chats list. Avatar + name (+ presence) centered; voice + video as trailing glass items.
    // The native back button (leading) owns the real edge-swipe-back gesture.
    @ToolbarContentBuilder private var chatToolbar: some ToolbarContent {
        // Avatar + name grouped tightly right after the back button (leading), not centered.
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink {
                ContactInfoView(cid: cid, name: title, photoUrl: photoUrl)
            } label: {
                HStack(spacing: 9) {
                    AvatarView(name: title, photoUrl: photoUrl, size: 46)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        if let sub = presenceSubtitle {
                            Text(sub).font(.caption2)
                                .foregroundStyle(repo.otherTyping ? Color.accentColor : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .tint(.primary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { CallService.shared.startCall(to: otherUid, name: title, photo: photoUrl) } label: {
                Image(systemName: "phone.fill")
            }
            .tint(.primary)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showVideoSoon = true } label: {
                Image(systemName: "video.fill")
            }
            .tint(.primary)
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        let reply = replyingTo.map {
            ReplyRef(id: $0.id, authorId: $0.authorId,
                     text: $0.isImage ? "📷 Photo" : ($0.isAudio ? "🎤 Voice message" : $0.text))
        }
        replyingTo = nil
        typingSent = false
        // Show the bubble INSTANTLY (optimistic), then reconcile when the server echoes it.
        let clientId = UUID().uuidString
        repo.addPending(Message(localText: text, authorId: me, clientId: clientId, replyTo: reply, sendState: .sending))
        Task {
            await ChatService.setTyping(cid, false)
            await deliver(text: text, reply: reply, clientId: clientId)
        }
    }

    // Re-try a failed message: flip its bubble back to .sending and send again.
    private func resend(_ m: Message) {
        let clientId = m.clientId ?? UUID().uuidString
        repo.removePending(clientId: clientId)
        if let data = m.localImageData {
            repo.addPending(Message(localImageData: data, width: m.width ?? 1, height: m.height ?? 1,
                                    authorId: me, clientId: clientId, sendState: .sending))
            Task {
                do { try await ChatService.sendImage(cid: cid, data: data, clientId: clientId) }
                catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
            }
        } else {
            repo.addPending(Message(localText: m.text, authorId: me, clientId: clientId,
                                    replyTo: m.replyTo, sendState: .sending))
            Task { await deliver(text: m.text, reply: m.replyTo, clientId: clientId) }
        }
    }

    // Send a photo with an instant optimistic bubble, then reconcile on the echo.
    private func sendPhoto(_ data: Data) async {
        let preview = ChatService.downscaledJPEG(data)
        let size = UIImage(data: preview)?.size ?? CGSize(width: 1, height: 1)
        let clientId = UUID().uuidString
        await MainActor.run {
            repo.addPending(Message(localImageData: preview, width: Double(size.width), height: Double(size.height),
                                    authorId: me, clientId: clientId, sendState: .sending))
        }
        do { try await ChatService.sendImage(cid: cid, data: data, clientId: clientId) }
        catch { await MainActor.run { repo.markFailed(clientId: clientId) } }
    }

    private func deliver(text: String, reply: ReplyRef?, clientId: String) async {
        do {
            try await ChatService.sendText(cid: cid, text: text, replyTo: reply, clientId: clientId)
        } catch {
            // Keep the message as a failed bubble (tap to retry); flag the encryption case.
            await MainActor.run {
                repo.markFailed(clientId: clientId)
                if error is MissingRecipientKeyError {
                    sendError = "\(title) hasn't opened Kulan yet, so encryption isn't set up. Your message will send once they do."
                }
            }
        }
    }

    // Call record as a WhatsApp-style message bubble. Outgoing = right-aligned accent
    // bubble; incoming & missed = left-aligned received bubble. Inside: a circular call
    // icon, bold status, a muted subtitle (duration or "Tap to call back"), and the
    // timestamp bottom-right. Tap anywhere to call back.
    private func callRow(_ m: Message) -> some View {
        let mine = m.callerUid == me
        let missed = m.callOutcome == "missed"
        let statusText = missed ? "Missed voice call" : "Voice call"
        let time = m.createdAt.formatted(date: .omitted, time: .shortened)
        // Second line: status + time, kept short so the bubble stays compact.
        let detail: String = {
            if missed { return "Tap to call back · \(time)" }
            if let d = m.callDuration, d > 0 { return "\(callLogDuration(d)) · \(time)" }
            return "\(mine ? "Outgoing" : "Incoming") · \(time)"
        }()
        let iconName = missed ? "phone.arrow.down.left" : (mine ? "phone.arrow.up.right" : "phone.arrow.down.left")
        let iconColor: Color = missed ? .red : (mine ? Theme.onAccent(dark) : Theme.accent(dark))
        let circleBg: Color = mine ? Color.white.opacity(0.22)
            : (missed ? Color.red.opacity(0.14) : Theme.accent(dark).opacity(0.14))

        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 60) }
            // No flexible Spacer inside -> the bubble hugs its content (compact, not a banner).
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle().fill(circleBg).frame(width: 34, height: 34)
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mine ? Theme.onAccent(dark) : .primary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(mine ? Theme.onAccent(dark).opacity(0.75) : .secondary)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(mine ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: UIScreen.main.bounds.width * 0.7, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 60) }
        }
        .contentShape(Rectangle())
        .onTapGesture { CallService.shared.startCall(to: otherUid, name: title, photo: photoUrl) }
    }

    // Call-log duration phrasing: "43 sec", "1:31", or "1:31:00".
    private func callLogDuration(_ s: Int) -> String {
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // "Unread Messages" divider (our design) — a thin accent line + label.
    private var unreadDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(height: 1)
            Text("Unread Messages").font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor).fixedSize()
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(height: 1)
        }
        .padding(.vertical, 8)
    }

    // Anchor the unread divider above the first unread message and land there on open.
    // Runs once; the last `unreadOnOpen` messages are treated as the unread block.
    private func anchorUnread(_ proxy: ScrollViewProxy) {
        guard !didAnchorUnread, unreadOnOpen > 0 else { return }
        let msgs = repo.messages
        guard !msgs.isEmpty else { return }
        let idx = max(0, msgs.count - unreadOnOpen)
        guard idx < msgs.count else { return }
        firstUnreadId = msgs[idx].id
        didAnchorUnread = true
        // Position instantly (no animated swoosh from the bottom) so the open feels clean.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            proxy.scrollTo(firstUnreadId, anchor: .top)
        }
    }

    // Toggle my reaction (re-tapping the same emoji removes it) and remember it as recent.
    private func react(_ m: Message, _ emoji: String) {
        let new = m.reactions[me] == emoji ? nil : emoji
        if let e = new { ReactionRecents.add(e) }
        Task { await ChatService.setReaction(cid: cid, messageId: m.id, emoji: new) }
    }

    private func dismissMenu() { withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil } }

    // Page in older history and keep the user's position (anchor the current top
    // message to the top after the older page prepends, so the list doesn't jump).
    private func loadOlderWithAnchor(_ proxy: ScrollViewProxy) {
        guard repo.canLoadOlder, !repo.loadingOlder else { return }
        let anchor = repo.items.first?.id
        repo.loadOlder {
            guard let anchor else { return }
            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    // Scroll to a message (e.g. the original of a tapped reply) and flash it briefly.
    private func jump(to id: String, _ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .center) }
        highlightId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if highlightId == id { withAnimation { highlightId = nil } }
        }
    }

    private func sendPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        defer { photoItem = nil }
        if let data = try? await item.loadTransferable(type: Data.self) {
            await sendPhoto(data)
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

    // True while the finger is held down recording (not yet locked).
    private var recordingHeld: Bool { recorder.isRecording && !recordLocked }
    // Live finger translation, clamped to up/left (the two meaningful directions).
    private var clampedDrag: CGSize {
        CGSize(width: max(-90, min(0, recordDrag.width)),
               height: max(-100, min(0, recordDrag.height)))
    }

    private var composer: some View {
        Group {
            if recordLocked { lockedRecordingBar } else { inputRow }
        }
        .padding(.horizontal, 16)   // spec: 16pt left/right margin
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: recordLocked)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {   // spec: 8pt gap + button -> input
            // Far-left circular "+" — hidden while actively recording so the row is clean.
            if !recordingHeld {
                Menu {
                    Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                    Button { showLibrary = true } label: { Label("Photo Library", systemImage: "photo") }
                } label: {
                    Image(systemName: sendingPhoto ? "ellipsis" : "plus")
                        .font(.system(size: 20, weight: .regular))   // spec: 20pt icon
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)                // spec: 40x40
                        .liquidGlass(Circle())   // real iOS 26 Liquid Glass
                }
                .tint(.primary)
                .transition(.scale.combined(with: .opacity))
            }

            // Input capsule: reply preview + divider, then text field OR the live record row.
            VStack(spacing: 0) {
                if let r = replyingTo, !recordingHeld {
                    replyPreviewRow(r)
                    Divider().padding(.horizontal, 12)
                }
                if recordingHeld { recordingHoldRow } else { textRow }
            }
            .frame(minHeight: 40)   // spec: 40pt base height
            // Native iMessage/WhatsApp field look: subtle neutral fill, not heavy glass.
            .background(fieldFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            // Right side: send (when typing) or the hold-to-record mic.
            if hasText {
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.accent(dark))
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                micButton
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hasText)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: recordingHeld)
    }

    // Text field + inline camera (send moved beside the capsule).
    private var textRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("Message", text: $input, axis: .vertical)
                .font(.system(size: 17))     // spec: SF Pro 17pt Regular
                .lineLimit(1...6)
                .focused($inputFocused)
                .padding(.leading, 14)       // spec: 14pt leading
                .padding(.vertical, 10)      // spec: 10pt vertical
                .onChange(of: input) { _, v in
                    let now = !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if now != typingSent {
                        typingSent = now
                        Task { await ChatService.setTyping(cid, now) }
                    }
                }
            if !hasText {
                Button { showCamera = true } label: {
                    Image(systemName: "camera").font(.system(size: 22)).foregroundStyle(.secondary)
                }
                .padding(.trailing, 12).padding(.bottom, 9)
            }
        }
    }

    // Live recording row inside the capsule: red dot + timer + "‹ slide to cancel".
    private var recordingHoldRow: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text(timeString(recorder.elapsed)).font(.subheadline.monospacedDigit())
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text("slide to cancel").font(.system(size: 14))
            }
            .foregroundStyle(recordCancelArmed ? Color.red : Color.secondary)
            // Fade the hint as the finger slides toward the cancel threshold.
            .opacity(1.0 - min(1.0, Double(-clampedDrag.width) / 90.0) * 0.6)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // The hold-to-record mic: grows + tints while held, follows the finger, shows a lock
    // hint above. Drag up to lock, drag left to cancel, release to send.
    private var micButton: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: recordingHeld ? 24 : 22, weight: .medium))
            .foregroundStyle(recordingHeld ? Theme.onAccent(dark) : Color.secondary)
            .frame(width: recordingHeld ? 56 : 40, height: recordingHeld ? 56 : 40)
            .background {
                if recordingHeld {
                    Circle().fill(recordCancelArmed ? Color.red : Theme.accent(dark))
                }
            }
            .offset(recordingHeld ? clampedDrag : .zero)
            .overlay(alignment: .top) { if recordingHeld { lockHint } }
            .gesture(recordGesture)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: recordingHeld)
    }

    // Floating lock pill above the mic; fills in as the finger approaches the lock point.
    private var lockHint: some View {
        let progress = min(1.0, Double(-clampedDrag.height) / 100.0)
        return VStack(spacing: 5) {
            Image(systemName: progress > 0.55 ? "lock.fill" : "lock.open.fill")
            Image(systemName: "chevron.up")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(progress > 0.55 ? Theme.accent(dark) : .secondary)
        .padding(.vertical, 10).padding(.horizontal, 9)
        .liquidGlass(Capsule())
        .offset(y: -84 - clampedDrag.height * 0.3)
        .opacity(0.6 + progress * 0.4)
        .transition(.opacity)
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !holdStarted {
                    holdStarted = true
                    recordCancelArmed = false
                    recordDrag = .zero
                    recorder.requestAndStart()
                    impact(.medium)               // start
                }
                recordDrag = v.translation
                let armed = v.translation.width < -90
                if armed != recordCancelArmed {
                    recordCancelArmed = armed
                    if armed { impact(.rigid) }    // entered cancel zone
                }
                if v.translation.height < -100 && !recordLocked { lockRecording() }
            }
            .onEnded { v in
                guard holdStarted else { return }  // already locked → ignore release
                holdStarted = false
                if recordLocked { return }
                let cancel = v.translation.width < -90
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { recordDrag = .zero }
                recordCancelArmed = false
                if cancel { recorder.cancel(); notify(.warning) }      // slide-to-cancel
                else { Task { await stopAndSendAudio() }; impact(.light) }   // release-to-send
            }
    }

    // Locked mode (finger lifted): delete · timer + waveform · send.
    private var lockedRecordingBar: some View {
        HStack(spacing: 12) {
            Button { cancelRecording() } label: {
                Image(systemName: "trash.fill").font(.system(size: 18)).foregroundStyle(.red)
                    .frame(width: 40, height: 40).liquidGlass(Circle())
            }
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(timeString(recorder.elapsed)).font(.subheadline.monospacedDigit())
                LiveWaveform(levels: recorder.levels, color: Theme.accent(dark))
                    .frame(maxWidth: .infinity, maxHeight: 22)
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .liquidGlass(Capsule())
            Button { sendRecording() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 38))
                    .foregroundStyle(Theme.accent(dark))
            }
        }
    }

    private func lockRecording() {
        holdStarted = false
        recordCancelArmed = false
        impact(.medium)   // lock
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            recordLocked = true
            recordDrag = .zero
        }
    }
    private func cancelRecording() {
        recorder.cancel()
        notify(.warning)
        resetRecordingState()
    }
    private func sendRecording() {
        Task { await stopAndSendAudio() }
        impact(.light)
        resetRecordingState()
    }
    private func resetRecordingState() {
        withAnimation { recordLocked = false; recordDrag = .zero; recordCancelArmed = false; holdStarted = false }
    }
    private func impact(_ s: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: s).impactOccurred()
    }
    private func notify(_ t: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(t)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func stopAndSendAudio() async {
        guard let (data, dur, wf) = recorder.finish() else { return }
        try? await ChatService.sendAudio(cid: cid, data: data, duration: dur, waveform: wf)
    }

    private func sendCaptured(_ data: Data) async {
        await sendPhoto(data)
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
    var onTapReactions: () -> Void = {}
    var onLongPress: (Message) -> Void = { _ in }
    var onResend: (Message) -> Void = { _ in }
    var onJumpTo: (String) -> Void = { _ in }
    var isHighlighted: Bool = false
    var isFirstInCluster: Bool = true
    var isLastInCluster: Bool = true
    var otherLastRead: Double = 0

    @State private var dragX: CGFloat = 0
    @AppStorage("readReceipts") private var readReceiptsPref = true

    private var myUid: String { AuthService.shared.uid ?? "" }
    private var myReaction: String? { message.reactions[myUid] }

    // Aggregate uid->emoji into (emoji, count, mine), most-popular first (Signal's logic,
    // our own pill design). Ties broken by emoji for a stable order.
    private var reactionCounts: [(emoji: String, count: Int, mine: Bool)] {
        Dictionary(grouping: message.reactions.values, by: { $0 })
            .map { (emoji: $0.key, count: $0.value.count, mine: message.reactions[myUid] == $0.key) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.emoji > $1.emoji }
    }

    private var isRead: Bool {
        message.createdAt.timeIntervalSince1970 * 1000 <= otherLastRead
    }

    private var timeString: String {
        message.createdAt.formatted(date: .omitted, time: .shortened)
    }

    // Time + status, shown INSIDE the bubble bottom-right. Status = clock while sending,
    // red "!" if it failed, single check when sent, filled check once the other read it.
    @ViewBuilder private var metaRow: some View {
        HStack(spacing: 3) {
            if message.edited { Text("edited").font(.system(size: 10)).italic() }
            Text(timeString).font(.system(size: 10))
            if isMe {
                switch message.sendState {
                case .sending:
                    Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
                case nil:
                    Image(systemName: (isRead && readReceiptsPref) ? "checkmark.circle.fill" : "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
        }
        .foregroundStyle(isMe ? Theme.onAccent(dark).opacity(0.7) : Color.secondary)
    }

    // Bubbles cap at 72% of screen width and wrap; the right (sent) / left (received)
    // edge stays a clean, uniform line regardless of length.
    private var maxBubbleWidth: CGFloat { UIScreen.main.bounds.width * 0.72 }

    // Photo bubble sized to the image's natural aspect (capped), not a forced square.
    private var imageDisplaySize: CGSize {
        let maxW: CGFloat = 240, maxH: CGFloat = 340
        guard let w = message.width, let h = message.height, w > 0, h > 0 else {
            return CGSize(width: 220, height: 220)
        }
        let aspect = CGFloat(w / h)
        var dw = maxW, dh = dw / aspect
        if dh > maxH { dh = maxH; dw = dh * aspect }
        return CGSize(width: dw, height: dh)
    }

    // Fused-cluster corners (our look): full 18pt outer corners; the interior corners
    // on the sending side shrink to 6pt so a same-sender run reads as one block.
    private var bubbleCorners: RectangleCornerRadii {
        let big: CGFloat = 18, small: CGFloat = 6
        if isMe {
            return RectangleCornerRadii(
                topLeading: big, bottomLeading: big,
                bottomTrailing: isLastInCluster ? big : small,
                topTrailing: isFirstInCluster ? big : small)
        } else {
            return RectangleCornerRadii(
                topLeading: isFirstInCluster ? big : small,
                bottomLeading: isLastInCluster ? big : small,
                bottomTrailing: big, topTrailing: big)
        }
    }

    // Reaction pills (our own design): up to 3 emoji+count capsules, my reaction tinted
    // with the brand accent, the rest neutral, and a "+N" capsule when there are more.
    @ViewBuilder private var reactionBadges: some View {
        let all = reactionCounts
        if !all.isEmpty {
            let shown = Array(all.prefix(3))
            let extra = all.count - shown.count
            HStack(spacing: 4) {
                ForEach(shown, id: \.emoji) { r in
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 12))
                        if r.count > 1 {
                            Text("\(r.count)").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(r.mine ? Color.accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(r.mine ? Color.accentColor.opacity(0.18) : Theme.received(dark), in: Capsule())
                    .overlay(Capsule().stroke(Color.accentColor.opacity(r.mine ? 0.9 : 0), lineWidth: 1))
                }
                if extra > 0 {
                    Text("+\(extra)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.received(dark), in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTapReactions() }
        }
    }

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 0) }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
                content   // long-press menu is now the native .contextMenu, attached in messageList
                reactionBadges
                if isMe && message.sendState == .failed {
                    Button { onResend(message) } label: {
                        Label("Not delivered. Tap to retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: isMe ? .trailing : .leading)
            if !isMe { Spacer(minLength: 0) }
        }
        // Brief accent flash when jumped-to via a reply tap.
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.accentColor.opacity(isHighlighted ? 0.12 : 0))
                .padding(.horizontal, -6)
        )
        .animation(.easeInOut(duration: 0.25), value: isHighlighted)
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
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
        } else if message.isImage {
            VStack(alignment: .leading, spacing: 4) {
                replyQuote
                Group {
                    if let data = message.localImageData, let ui = UIImage(data: data) {
                        Image(uiImage: ui).resizable().scaledToFill()          // optimistic local photo
                    } else if let url = message.imageUrl {
                        SecureImageView(imageUrl: url, enc: message.enc, cid: cid)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.18))
                    }
                }
                .frame(width: imageDisplaySize.width, height: imageDisplaySize.height)
                .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
                .overlay {   // dim + spinner while uploading
                    if message.sendState == .sending {
                        ZStack { Color.black.opacity(0.2); ProgressView().tint(.white) }
                            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    metaRow
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(7)
                }
                .onTapGesture {
                    if message.sendState == .failed { onResend(message) }
                    else if message.localImageData == nil { onTapImage(message) }   // only open uploaded photos
                }
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
                    if isLastInCluster { metaRow.padding(.bottom, 1) }   // time once per cluster
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(isMe ? Theme.accent(dark) : Theme.received(dark))
            .clipShape(UnevenRoundedRectangle(cornerRadii: bubbleCorners, style: .continuous))
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
            // Tint the quote box with the (contrasting) text color so it's always visible —
            // the old white tint vanished on the white "mine" bubble in dark mode.
            .background(fg.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { onJumpTo(reply.id) }   // jump to the original message
        }
    }
}

// In-list typing indicator: a received-style bubble with three waving dots.
struct TypingBubble: View {
    let dark: Bool
    @State private var animating = false

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .scaleEffect(animating ? 1 : 0.5)
                        .opacity(animating ? 1 : 0.4)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: animating)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.received(dark))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 0)
        }
        .onAppear { animating = true }
    }
}

// Edit-message sheet: native iOS editor with Cancel / Save. Save is disabled when the
// text is empty or unchanged, so an edit is always a real, non-empty change.
struct EditMessageSheet: View {
    let original: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(original: String, onSave: @escaping (String) -> Void) {
        self.original = original
        self.onSave = onSave
        _text = State(initialValue: original)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmed.isEmpty && trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Message", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...10)
                    .padding(12)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($focused)
                    .padding()
                Spacer()
            }
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(trimmed); dismiss() }
                        .fontWeight(.semibold).disabled(!canSave)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
