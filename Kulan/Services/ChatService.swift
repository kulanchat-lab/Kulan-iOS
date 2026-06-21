import Foundation
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
    static func sendText(cid: String, text: String, replyTo: ReplyRef? = nil) async throws {
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
        let msgRef = convRef.collection("messages").document()

        let batch = db.batch()
        var msg: [String: Any] = [
            "text": cipher,
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ]
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
    static func sendImage(cid: String, data: Data) async throws {
        let (cipher, meta) = try await Crypto.shared.encryptBytes(cid, data)
        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        let convRef = db.collection("conversations").document(cid)
        let msgRef = convRef.collection("messages").document()

        let ref = Storage.storage().reference().child("chat/\(cid)/\(msgRef.documentID).enc")
        let sm = StorageMetadata(); sm.contentType = "application/octet-stream"
        _ = try await ref.putDataAsync(cipher, metadata: sm)
        let url = try await ref.downloadURL().absoluteString

        let batch = db.batch()
        batch.setData([
            "type": "image",
            "imageUrl": url,
            "enc": ["v": meta.v, "n": meta.n, "k": meta.k, "kn": meta.kn],
            "text": "",
            "authorId": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ], forDocument: msgRef)
        batch.updateData([
            "lastMessage": "📷 Photo",   // plaintext preview (server never sees the image)
            "updatedAt": FieldValue.serverTimestamp(),
            "unreadCount.\(other)": FieldValue.increment(Int64(1)),
        ], forDocument: convRef)
        try await batch.commit()
    }

    static func deleteMessage(cid: String, messageId: String) async {
        try? await db.collection("conversations").document(cid)
            .collection("messages").document(messageId).delete()
    }

    static func setTyping(_ cid: String, _ typing: Bool) async {
        try? await db.collection("conversations").document(cid)
            .setData(["typing": [uid: typing]], merge: true)
    }

    static func resetUnread(_ cid: String) async {
        try? await db.collection("conversations").document(cid)
            .updateData(["unreadCount.\(uid)": 0])
    }

    static func setPinned(_ cid: String, _ value: Bool) async {
        try? await db.collection("conversations").document(cid)
            .setData(["pinnedBy": [uid: value]], merge: true)
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

    static func setBlocked(_ cid: String, _ value: Bool) async {
        try? await db.collection("conversations").document(cid)
            .setData(["blockedBy": [uid: value]], merge: true)
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
