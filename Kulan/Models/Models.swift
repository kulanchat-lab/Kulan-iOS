import Foundation
import FirebaseFirestore

// Domain models. Field names match the existing Firestore schema EXACTLY so the
// native client reads the same data the RN app writes (see MIGRATION.md).

struct UserProfile: Identifiable, Equatable {
    let id: String            // uid
    var name: String
    var handle: String
    var about: String
    var photoUrl: String?
    var publicKeyB64: String?

    init(id: String, data: [String: Any]) {
        self.id = id
        self.name = data["name"] as? String ?? ""
        self.handle = data["handle"] as? String ?? ""
        self.about = data["about"] as? String ?? ""
        self.photoUrl = data["photoUrl"] as? String
        self.publicKeyB64 = data["publicKey"] as? String
    }
}

struct ReplyRef: Equatable {
    var id: String
    var authorId: String
    var text: String          // decrypted snippet
}

// Local delivery state for a message I'm sending. nil = a confirmed server message
// (its receipt is derived from the other person's lastRead instead).
enum MessageSendState: Equatable { case sending, failed }

struct Message: Identifiable, Equatable {
    let id: String
    var authorId: String
    var text: String          // DECRYPTED for display
    var type: String?         // "image" for photos, "audio" for voice notes
    var imageUrl: String?
    var audioUrl: String?
    var duration: Double?     // voice note length (seconds)
    var enc: EncMeta?
    var clientId: String?
    var replyTo: ReplyRef?
    var reactions: [String: String]   // uid -> decrypted emoji
    var createdAt: Date
    var sendState: MessageSendState? = nil  // set only on local optimistic messages

    var isImage: Bool { type == "image" && (imageUrl?.isEmpty == false) }
    var isAudio: Bool { type == "audio" && (audioUrl?.isEmpty == false) }

    /// Local optimistic message shown instantly before the server confirms it.
    /// `id` = clientId until the server echo (matched by clientId) replaces it.
    init(localText: String, authorId: String, clientId: String, replyTo: ReplyRef?, sendState: MessageSendState) {
        self.id = clientId
        self.authorId = authorId
        self.text = localText
        self.clientId = clientId
        self.replyTo = replyTo
        self.reactions = [:]
        self.createdAt = Date()
        self.sendState = sendState
    }

    init(id: String, data: [String: Any], cid: String, crypto: Crypto) {
        self.id = id
        self.authorId = data["authorId"] as? String ?? ""
        self.text = crypto.decrypt(data["text"] as? String ?? "", cid: cid)
        self.type = data["type"] as? String
        self.imageUrl = data["imageUrl"] as? String
        self.audioUrl = data["audioUrl"] as? String
        self.duration = (data["duration"] as? NSNumber)?.doubleValue
        self.clientId = data["clientId"] as? String
        self.enc = (data["enc"] as? [String: Any]).flatMap(EncMeta.init(map:))
        // Drop entries that fail to decrypt (empty) so a broken record can't render a garbage badge.
        self.reactions = (data["reactions"] as? [String: String])?
            .compactMapValues { c in let e = crypto.decrypt(c, cid: cid); return e.isEmpty ? nil : e } ?? [:]
        if let r = data["replyTo"] as? [String: Any] {
            self.replyTo = ReplyRef(
                id: r["id"] as? String ?? "",
                authorId: r["authorId"] as? String ?? "",
                text: crypto.decrypt(r["text"] as? String ?? "", cid: cid)
            )
        }
        if let ts = data["createdAt"] as? Timestamp {
            self.createdAt = ts.dateValue()
        } else {
            self.createdAt = Date()
        }
    }
}

struct Conversation: Identifiable, Equatable, Hashable {
    let id: String            // cid ("uidA_uidB")
    var users: [String]
    var names: [String: String]
    var photos: [String: String]
    var lastMessageCipher: String
    var unreadCount: [String: Int]
    var typing: [String: Bool]
    var mutedBy: [String: Double]      // expiry in ms
    var pinnedBy: [String: Bool]
    var archivedBy: [String: Bool]
    var clearedAt: [String: Double]    // delete-for-me, ms
    var blockedBy: [String: Bool]
    var blockedAt: [String: Double]    // when each user blocked (ms) — hides later messages
    var pinOrder: [String: Double]     // per-user manual order for pinned chats
    var pinnedMessageId: String        // a pinned message in this chat ("" = none)
    var updatedAtMillis: Double

    init(id: String, data: [String: Any]) {
        self.id = id
        self.users = data["users"] as? [String] ?? []
        self.names = data["names"] as? [String: String] ?? [:]
        self.photos = data["photos"] as? [String: String] ?? [:]
        self.lastMessageCipher = data["lastMessage"] as? String ?? ""
        self.unreadCount = intMap(data["unreadCount"])
        self.typing = boolMap(data["typing"])
        self.mutedBy = doubleMap(data["mutedBy"])
        self.pinnedBy = boolMap(data["pinnedBy"])
        self.archivedBy = boolMap(data["archivedBy"])
        self.clearedAt = doubleMap(data["clearedAt"])
        self.blockedBy = boolMap(data["blockedBy"])
        self.blockedAt = doubleMap(data["blockedAt"])
        self.pinOrder = doubleMap(data["pinOrder"])
        self.pinnedMessageId = data["pinnedMessageId"] as? String ?? ""
        if let ts = data["updatedAt"] as? Timestamp {
            self.updatedAtMillis = ts.dateValue().timeIntervalSince1970 * 1000
        } else {
            self.updatedAtMillis = 0
        }
    }

    func otherUid(_ me: String) -> String { users.first { $0 != me } ?? "" }
    func name(for me: String) -> String { names[otherUid(me)] ?? "User" }
    func photoUrl(for me: String) -> String? { photos[otherUid(me)] }
    func unread(_ me: String) -> Int { unreadCount[me] ?? 0 }
    func isMuted(_ me: String, now: Double) -> Bool { (mutedBy[me] ?? 0) > now }
    func isBlockedByMe(_ me: String) -> Bool { blockedBy[me] ?? false }
    func blockedAtMillis(_ me: String) -> Double { blockedAt[me] ?? 0 }
    // Silent block in the chat LIST: a chat I blocked whose latest activity is the
    // blocked person's post-block message — its preview/time/order must be frozen.
    func leaksBlocked(_ me: String) -> Bool {
        isBlockedByMe(me) && blockedAtMillis(me) > 0 && updatedAtMillis > blockedAtMillis(me)
    }
    /// Sort/time key that ignores the blocked person's later messages (freezes at block time).
    func displayUpdatedAt(_ me: String) -> Double {
        leaksBlocked(me) ? blockedAtMillis(me) : updatedAtMillis
    }
    func isPinned(_ me: String) -> Bool { pinnedBy[me] ?? false }
    /// Manual order for pinned chats; defaults to recency so never-moved pins stay sensible.
    func pinRank(_ me: String) -> Double { pinOrder[me] ?? updatedAtMillis }
    func isArchived(_ me: String) -> Bool { archivedBy[me] ?? false }
    /// "delete for me" until a newer message arrives (parity with RN Db.isCleared).
    func isCleared(_ me: String) -> Bool { updatedAtMillis <= (clearedAt[me] ?? 0) }
}

extension EncMeta {
    init?(map: [String: Any]) {
        guard let n = map["n"] as? String,
              let k = map["k"] as? String,
              let kn = map["kn"] as? String else { return nil }
        self.init(v: (map["v"] as? Int) ?? 1, n: n, k: k, kn: kn)
    }
}

// Firestore returns map values as Any (NSNumber-backed); convert safely.
private func intMap(_ any: Any?) -> [String: Int] {
    guard let m = any as? [String: Any] else { return [:] }
    return m.compactMapValues { ($0 as? NSNumber)?.intValue }
}
private func doubleMap(_ any: Any?) -> [String: Double] {
    guard let m = any as? [String: Any] else { return [:] }
    return m.compactMapValues { ($0 as? NSNumber)?.doubleValue }
}
private func boolMap(_ any: Any?) -> [String: Bool] {
    guard let m = any as? [String: Any] else { return [:] }
    return m.compactMapValues { $0 as? Bool }
}
