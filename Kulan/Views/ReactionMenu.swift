import SwiftUI
import UIKit

// Long-press reaction + actions menu, the any-emoji picker, and the "who reacted"
// sheet. Signal's logic (one emoji per user, recents, full picker, reactor list),
// our own Kulan design.

// Recently-used reaction emoji, persisted so the quick bar adapts to the user.
enum ReactionRecents {
    private static let key = "reactionRecents"
    static func get() -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: " ").map(String.init)
    }
    static func add(_ emoji: String) {
        var r = get().filter { $0 != emoji }
        r.insert(emoji, at: 0)
        UserDefaults.standard.set(r.prefix(10).joined(separator: " "), forKey: key)
    }
}

// Curated emoji set for the "more" grid (real emoji, no fakes).
enum EmojiCatalog {
    static let all: [String] = [
        "❤️","👍","👎","😂","🥰","😮","😢","😡","🙏","🔥","🎉","👏",
        "😅","😍","😘","😎","🤔","🤗","🤩","😴","😭","😱","🤣","🙄",
        "💯","✨","⭐️","💔","💕","💪","🙌","👌","✌️","🤝","🫶","👀",
        "✅","❌","⚡️","🌟","🎊","🥳","😇","😉","😋","😜","🤪","😏",
        "🤤","😬","😳","🥺","😤","😩","🤯","😶","😐","🙃","☺️","🥲"
    ]
}

// Floating dim overlay: a quick-emoji bar on top, message actions below.
struct ReactionMenuOverlay: View {
    let message: Message
    let dark: Bool
    let isMe: Bool
    let myReaction: String?
    var onPick: (String) -> Void
    var onMore: () -> Void
    var onReply: () -> Void
    var onPin: () -> Void
    var onCopy: () -> Void
    var onDelete: () -> Void
    var onDismiss: () -> Void

    // Recents first, then the defaults, deduped and capped at 6.
    private var quick: [String] {
        var set = ReactionRecents.get()
        for e in ["❤️", "👍", "😂", "😮", "😢", "🙏"] where !set.contains(e) { set.append(e) }
        return Array(set.prefix(6))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(spacing: 14) {
                emojiBar
                actions
            }
            .padding(20)
        }
    }

    private var emojiBar: some View {
        HStack(spacing: 8) {
            ForEach(quick, id: \.self) { e in
                Button { onPick(e) } label: {
                    Text(e).font(.system(size: 30))
                        .padding(6)
                        .background(myReaction == e ? Color.accentColor.opacity(0.22) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
            }
            Button { onMore() } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(Theme.received(dark), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .liquidGlass(Capsule())   // real iOS 26 Liquid Glass
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)   // float above the chat
    }

    private var actions: some View {
        VStack(spacing: 0) {
            row("Reply", "arrowshape.turn.up.left", onReply)
            if !message.isImage && !message.text.isEmpty {
                Divider().padding(.leading, 16)
                row("Copy", "doc.on.doc") { UIPasteboard.general.string = message.text; onCopy() }
            }
            Divider().padding(.leading, 16)
            row("Pin", "pin", onPin)
            if isMe {
                Divider().padding(.leading, 16)
                row("Delete", "trash", onDelete, destructive: true)
            }
        }
        .frame(width: 250)
        .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))   // real Liquid Glass
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    @ViewBuilder
    private func row(_ title: String, _ icon: String, _ action: @escaping () -> Void, destructive: Bool = false) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: icon)
            }
            .font(.system(size: 16))
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Full any-emoji grid for "more".
struct EmojiMorePicker: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let cols = Array(repeating: GridItem(.flexible()), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(EmojiCatalog.all, id: \.self) { e in
                        Button { onPick(e); dismiss() } label: { Text(e).font(.system(size: 30)) }
                            .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// "Who reacted" — reactor name + their emoji. Real data, no fakes.
struct ReactorsSheet: View {
    let reactions: [String: String]      // uid -> emoji
    let nameFor: (String) -> String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(reactions.sorted { $0.key < $1.key }, id: \.key) { uid, emoji in
                    HStack {
                        Text(nameFor(uid)).font(.body)
                        Spacer()
                        Text(emoji).font(.title3)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
