import SwiftUI

// Rich native context-menu peek for a chat row. Shown above the action menu when a row
// is long-pressed (the modern .contextMenu(menuItems:preview:) API). It renders a
// truthful snapshot derived from the REAL last message — a voice-note bubble, a
// missed-call widget, a photo chip, or a text bubble — plus a real date separator.
//
// Note: a context-menu preview is a non-interactive snapshot, so controls inside it
// (e.g. a "Call Back" button) can't receive taps; tapping the peek opens the chat.
struct ChatPeekPreview: View {
    let conv: Conversation
    let me: String
    let dark: Bool

    // The list-level lastMessage: media/call previews are stored as plaintext emoji
    // strings; text messages are ciphertext we decrypt for display.
    private var raw: String { conv.lastMessageCipher }
    private var isMissed: Bool { raw.localizedCaseInsensitiveContains("missed") }
    private var isCall: Bool { raw.hasPrefix("📞") }
    private var isVoice: Bool { raw.hasPrefix("🎤") }
    private var isPhoto: Bool { raw.hasPrefix("📷") }
    private var text: String {
        let d = Crypto.shared.decrypt(raw, cid: conv.id)
        return d.isEmpty ? (raw.isEmpty ? "Say hello 👋" : raw) : d
    }

    private var dateLabel: String {
        let ms = conv.displayUpdatedAt(me)
        guard ms > 0 else { return "Today" }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AvatarView(name: conv.name(for: me), photoUrl: conv.photoUrl(for: me), size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conv.name(for: me)).font(.headline)
                    Text("end-to-end encrypted").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Text(dateLabel)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            HStack { bubble; Spacer(minLength: 0) }
        }
        .padding(16)
        .frame(width: 300)
        .background(dark ? Color(hex: 0x1C1C1E) : Color.white)
    }

    @ViewBuilder private var bubble: some View {
        if isMissed {
            callWidget(icon: "phone.arrow.down.left", tint: .red,
                       title: "Missed voice call", subtitle: "Tap to call back")
        } else if isCall {
            callWidget(icon: "phone.fill", tint: Theme.accent(dark),
                       title: "Voice call", subtitle: "Tap to call back")
        } else if isVoice {
            voiceBubble
        } else if isPhoto {
            callWidget(icon: "photo", tint: Theme.accent(dark), title: "Photo", subtitle: "")
        } else {
            Text(text)
                .font(.system(size: 15))
                .lineLimit(4)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.received(dark))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // Voice-note bubble: play glyph + a representative waveform + label.
    private var voiceBubble: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.fill").font(.system(size: 15))
                .foregroundStyle(Theme.accent(dark))
            HStack(spacing: 2) {
                ForEach(0..<22, id: \.self) { i in
                    Capsule().fill(Theme.accent(dark).opacity(0.35))
                        .frame(width: 2, height: [6, 14, 9, 18, 11, 7].randomElementStable(i))
                }
            }
            Text("Voice message").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.received(dark))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func callWidget(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.received(dark))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// Deterministic "random-looking" bar heights (no Date/Math.random — stable across renders).
private extension Array where Element == CGFloat {
    func randomElementStable(_ seed: Int) -> CGFloat { self[(seed &* 7 &+ 3) % count] }
}
