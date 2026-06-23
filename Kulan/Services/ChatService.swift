import Foundation
import UIKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

/// Write-side operations (port of the RN Db writes). All E2EE goes through Crypto.
enum ChatService {
    static var db: Firestore { Firestore.firestore() }
    static var uid: String { Auth.auth().currentUser?.uid ?? "" }

    static func convId(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "_")
    }

    /// Create (or touch) a 1:1 conversation. Only writes photo keys we actually have,
    /// so re-opening never wipes an existing photo (parity with the RN fix).
    @discardableResult
    static func openConversation(other: UserProfile) async throws -> String {
        let cid = convId(uid, other.id)
        let me = await ProfileStore.shared.fetch(uid)
        var photos: [String: String] = [:]
        if let p = me?.photoUrl, !p.isEmpty { photos[uid] = p }
        if let p = other.photoUrl, !p.isEmpty { photos[other.id] = p }

        try await db.collection("conversations").document(cid).setData([
            "users": [uid, other.id],
            "names": [uid: me?.name ?? "Me", other.id: other.name.isEmpty ? other.handle : other.name],
            "photos": photos,
            "unreadCount": [uid: 0, other.id: 0],
            "typing": [uid: false, other.id: false],
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)
        return cid
    }

    /// Encrypt + send a text message and bump the conversation. Throws
    /// MissingRecipientKeyError if the recipient has no key yet (never sends plaintext).
    static func sendText(cid: String, text: String, replyTo: ReplyRef? = nil, clientId: String? = nil) async throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        let cipher = try await Crypto.shared.encryptForConversation(cid, t)
        var replyEnc: [String: Any]?
        if let r = replyTo {
            let rc = try await Crypto.shared.encryptForConversation(cid, r.text)
            replyEnc = ["id": r.id, "authorId": r.authorId, "text": rc]
        }

        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        let convRef = db.collection("conversations").document(cid)

        // Ensure the conversation exists BEFORE the message. The rules require
        // convData().users to authorize a message create; on a brand-new chat the
        // create otherwise loses the race and is rolled back server-side (message
        // "sends" locally then silently vanishes). Awaiting this first send keeps
        // the writes ordered so the conv is committed before the message.
        try await convRef.setData([
            "users": [uid, other],
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)

        let msgRef = convRef.collection("messages").document()
        let batch = db.batch()
        var msg: [String: Any] = [
            "text": cipher,
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let clientId { msg["clientId"] = clientId }   // lets the client reconcile its optimistic copy
        if let replyEnc { msg["replyTo"] = replyEnc }
        batch.setData(msg, forDocument: msgRef)
        batch.updateData([
            "lastMessage": cipher,
            "updatedAt": FieldValue.serverTimestamp(),
            "unreadCount.\(other)": FieldValue.increment(Int64(1)),
        ], forDocument: convRef)
        try await batch.commit()
    }

    /// Encrypt + send a photo. The JPEG bytes are sealed with Crypto.encryptBytes
    /// and the ciphertext is uploaded to Storage; the server never sees the image.
    /// Downscale + recompress a photo before encrypting/uploading. Cuts upload size
    /// (and failure rate) massively; full-res camera/library photos are huge.
    static func downscaledJPEG(_ data: Data, maxDimension: CGFloat = 1600, quality: CGFloat = 0.72) -> Data {
        guard let img = UIImage(data: data) else { return data }
        let longEdge = max(img.size.width, img.size.height)
        let scale = min(1, maxDimension / longEdge)
        if scale >= 1 { return img.jpegData(compressionQuality: quality) ?? data }
        let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: newSize).image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality) ?? data
    }

    static func sendImage(cid: String, data rawData: Data, clientId: String? = nil) async throws {
        let data = downscaledJPEG(rawData)
        let (cipher, meta) = try await Crypto.shared.encryptBytes(cid, data)
        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        let convRef = db.collection("conversations").document(cid)

        // Same ordering guarantee as sendText — conversation must exist first.
        try await convRef.setData([
            "users": [uid, other],
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)

        let msgRef = convRef.collection("messages").document()
        let ref = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID).enc")
        let sm = StorageMetadata(); sm.contentType = "application/octet-stream"
        _ = try await ref.putDataAsync(cipher, metadata: sm)
        let url = try await ref.downloadURL().absoluteString

        let batch = db.batch()
        var imgMsg: [String: Any] = [
            "type": "image",
            "imageUrl": url,
            "enc": ["v": meta.v, "n": meta.n, "k": meta.k, "kn": meta.kn],
            "text": "",
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        if let clientId { imgMsg["clientId"] = clientId }   // reconcile the optimistic bubble
        batch.setData(imgMsg, forDocument: msgRef)
        batch.updateData([
            "lastMessage": "📷 Photo",   // plaintext preview (server never sees the image)
            "updatedAt": FieldValue.serverTimestamp(),
            "unreadCount.\(other)": FieldValue.increment(Int64(1)),
        ], forDocument: convRef)
        try await batch.commit()
    }

    /// Encrypt + send a voice note. Same E2EE pipeline as photos: the m4a bytes
    /// are sealed and the ciphertext uploaded; the server never hears the audio.
    static func sendAudio(cid: String, data: Data, duration: Double) async throws {
        let (cipher, meta) = try await Crypto.shared.encryptBytes(cid, data)
        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        let convRef = db.collection("conversations").document(cid)

        try await convRef.setData([
            "users": [uid, other],
            "updatedAt": FieldValue.serverTimestamp(),
        ], merge: true)

        let msgRef = convRef.collection("messages").document()
        let ref = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID).m4a.enc")
        let sm = StorageMetadata(); sm.contentType = "application/octet-stream"
        _ = try await ref.putDataAsync(cipher, metadata: sm)
        let url = try await ref.downloadURL().absoluteString

        let batch = db.batch()
        batch.setData([
            "type": "audio",
            "audioUrl": url,
            "duration": duration,
            "enc": ["v": meta.v, "n": meta.n, "k": meta.k, "kn": meta.kn],
            "text": "",
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: msgRef)
        batch.updateData([
            "lastMessage": "🎤 Voice message",
            "updatedAt": FieldValue.serverTimestamp(),
            "unreadCount.\(other)": FieldValue.increment(Int64(1)),
        ], forDocument: convRef)
        try await batch.commit()
    }

    /// Recent image messages in a conversation (for the Shared Media section).
    /// Filters client-side to avoid needing a composite index.
    static func sharedMedia(_ cid: String) async -> [Message] {
        do {
            let snap = try await db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt", descending: true)
                .limit(to: 60).getDocuments()
            return snap.documents
                .map { Message(id: $0.documentID, data: $0.data(), cid: cid, crypto: Crypto.shared) }
                .filter { $0.isImage }
        } catch {
            return []
        }
    }

    /// Delete all of MY messages in this conversation ("Clear chat" for me).
    static func clearMyMessages(_ cid: String) async {
        do {
            let snap = try await db.collection("conversations").document(cid).collection("messages")
                .whereField("authorId", isEqualTo: uid).getDocuments()
            let batch = db.batch()
            snap.documents.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
        } catch { /* ignore */ }
    }

    /// Set or clear my emoji reaction on a message. The emoji is E2E-encrypted
    /// (same as text) so the server never sees the reaction.
    static func setReaction(cid: String, messageId: String, emoji: String?) async {
        let ref = db.collection("conversations").document(cid)
            .collection("messages").document(messageId)
        if let emoji, let enc = try? await Crypto.shared.encryptForConversation(cid, emoji) {
            // Dotted field update (matches the delete path) — only touches my own key,
            // so concurrent reactions from both users never clobber each other.
            try? await ref.updateData(["reactions.\(uid)": enc])
        } else {
            try? await ref.updateData(["reactions.\(uid)": FieldValue.delete()])
        }
    }

    static func deleteMessage(cid: String, messageId: String) async {
        try? await db.collection("conversations").document(cid)
            .collection("messages").document(messageId).delete()
    }

    static func setTyping(_ cid: String, _ typing: Bool) async {
        try? await db.collection("conversations").document(cid)
            .setData(["typing": [uid: typing]], merge: true)
    }

    /// My unread count for this conversation — read once on open (before reset) to
    /// anchor the "Unread Messages" divider.
    static func myUnread(_ cid: String) async -> Int {
        let snap = try? await db.collection("conversations").document(cid).getDocument()
        let m = snap?.data()?["unreadCount"] as? [String: Any]
        return (m?[uid] as? NSNumber)?.intValue ?? 0
    }

    static func resetUnread(_ cid: String) async {
        try? await db.collection("conversations").document(cid)
            .updateData(["unreadCount.\(uid)": 0])
    }

    /// Manually flag a chat as unread (Telegram-style) — shows a badge until reopened.
    static func markUnread(_ cid: String) async {
        try? await db.collection("conversations").document(cid)
            .updateData(["unreadCount.\(uid)": 1])
    }

    /// Mark this conversation read up to now (drives the other person's read receipts).
    static func markRead(_ cid: String) async {
        try? await db.collection("conversations").document(cid)
            .setData(["lastRead": [uid: FieldValue.serverTimestamp()]], merge: true)
    }

    static func setPinned(_ cid: String, _ value: Bool) async {
        try? await db.collection("conversations").document(cid)
            .setData(["pinnedBy": [uid: value]], merge: true)
    }

    /// Per-user manual order value for a pinned chat (fractional indexing).
    static func setPinOrder(_ cid: String, _ value: Double) async {
        try? await db.collection("conversations").document(cid)
            .setData(["pinOrder": [uid: value]], merge: true)
    }

    /// Pin (or clear, with nil) a message in a conversation — shared by both members.
    static func setPinnedMessage(_ cid: String, _ messageId: String?) async {
        try? await db.collection("conversations").document(cid)
            .setData(["pinnedMessageId": messageId ?? ""], merge: true)
    }

    static func setArchived(_ cid: String, _ value: Bool) async {
        try? await db.collection("conversations").document(cid)
            .setData(["archivedBy": [uid: value]], merge: true)
    }

    static func setMuted(_ cid: String, _ value: Bool) async {
        let until: Double = value ? 9_999_999_999_999 : 0
        try? await db.collection("conversations").document(cid)
            .setData(["mutedBy": [uid: until]], merge: true)
    }

    /// Mute until a specific epoch-ms time (0 = unmute, far-future = always).
    static func setMute(_ cid: String, until: Double) async {
        try? await db.collection("conversations").document(cid)
            .setData(["mutedBy": [uid: until]], merge: true)
    }

    /// Shared mute-duration options (Signal-style). Pass nil for "Always".
    static func muteUntil(_ hours: Double?) -> Double {
        guard let hours else { return 9_999_999_999_999 }
        return Date().timeIntervalSince1970 * 1000 + hours * 3_600_000
    }

    static func setBlocked(_ cid: String, _ value: Bool) async {
        var data: [String: Any] = ["blockedBy": [uid: value]]
        let now = Date().timeIntervalSince1970 * 1000
        // Stamp block start / unblock time so the blocker hides exactly the messages
        // that arrived DURING the block — and keeps hiding them after unblock
        // (never delivered, like WhatsApp). Older history stays visible.
        if value { data["blockedAt"] = [uid: now] } else { data["blockClearedAt"] = [uid: now] }
        try? await db.collection("conversations").document(cid).setData(data, merge: true)
    }

    /// "Delete for me" — hides the thread until a newer message arrives (clearedAt).
    static func deleteForMe(_ cid: String) async {
        try? await db.collection("conversations").document(cid).setData([
            "clearedAt": [uid: Date().timeIntervalSince1970 * 1000],
            "unreadCount": [uid: 0],
        ], merge: true)
    }

    // MARK: - Discovery

    static func findByHandle(_ handle: String) async -> UserProfile? {
        let h = handle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !h.isEmpty else { return nil }
        do {
            let snap = try await db.collection("users")
                .whereField("handleLower", isEqualTo: h)
                .limit(to: 1).getDocuments()
            guard let d = snap.documents.first else { return nil }
            return UserProfile(id: d.documentID, data: d.data())
        } catch {
            print("findByHandle failed:", error)
            return nil
        }
    }

    static func searchUsers(prefix: String) async -> [UserProfile] {
        let q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        do {
            let snap = try await db.collection("users")
                .order(by: "handleLower")
                .start(at: [q]).end(at: [q + "\u{f8ff}"])
                .limit(to: 20).getDocuments()
            return snap.documents.compactMap { d -> UserProfile? in
                let u = UserProfile(id: d.documentID, data: d.data())
                return u.id == uid ? nil : u
            }
        } catch {
            print("searchUsers failed:", error)
            return []
        }
    }
}
