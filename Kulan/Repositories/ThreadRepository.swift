import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

/// Live messages for one conversation. Keys are preloaded before the listener
/// attaches so decryption is ready on the first emission.
@Observable
final class ThreadRepository {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var convListener: ListenerRegistration?
    private var userListener: ListenerRegistration?
    let cid: String

    var messages: [Message] = []           // confirmed server messages
    var pending: [Message] = []            // optimistic, not yet echoed back
    // Decrypt cache: reuse already-built messages so each snapshot only decrypts
    // new/changed docs (reactions are the only mutable field) instead of all N.
    private var cache: [String: Message] = [:]
    private var rawReactions: [String: [String: String]] = [:]
    var otherTyping = false
    var otherOnline = false
    var otherLastActive: Date?
    var otherLastReadMillis: Double = 0
    var iBlocked = false
    var pinnedMessageId = ""

    init(cid: String) { self.cid = cid }

    /// Display list = confirmed server messages + any optimistic ones not yet echoed.
    var items: [Message] {
        let echoed = Set(messages.compactMap { $0.clientId })
        return messages + pending.filter { p in !(p.clientId.map(echoed.contains) ?? false) }
    }

    func addPending(_ m: Message) { pending.append(m) }
    func markFailed(clientId: String) {
        if let i = pending.firstIndex(where: { $0.clientId == clientId }) { pending[i].sendState = .failed }
    }
    func removePending(clientId: String) { pending.removeAll { $0.clientId == clientId } }

    func start() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        stop()
        // Conversation doc: the other person's typing flag + their read timestamp.
        convListener = db.collection("conversations").document(cid)
            .addSnapshotListener { [weak self] snap, _ in
                let d = snap?.data()
                self?.otherTyping = (d?["typing"] as? [String: Any])?[other] as? Bool ?? false
                self?.iBlocked = (d?["blockedBy"] as? [String: Any])?[uid] as? Bool ?? false
                self?.pinnedMessageId = d?["pinnedMessageId"] as? String ?? ""
                if let ts = (d?["lastRead"] as? [String: Any])?[other] as? Timestamp {
                    self?.otherLastReadMillis = ts.dateValue().timeIntervalSince1970 * 1000
                }
            }
        // The other user's presence (online / last active).
        userListener = db.collection("users").document(other)
            .addSnapshotListener { [weak self] snap, _ in
                let d = snap?.data()
                self?.otherOnline = d?["online"] as? Bool ?? false
                if let ts = d?["lastActive"] as? Timestamp { self?.otherLastActive = ts.dateValue() }
            }
        Task {
            try? await Crypto.shared.ensureReady()
            _ = await Crypto.shared.preloadKey(other)
            listener = db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt")
                .addSnapshotListener { [weak self] snap, _ in
                    guard let self, let snap else { return }
                    // Don't blank an open thread on an empty offline snapshot.
                    if snap.metadata.isFromCache && snap.documents.isEmpty && !self.messages.isEmpty { return }
                    self.messages = snap.documents.map { doc -> Message in
                        let id = doc.documentID, data = doc.data()
                        let raw = (data["reactions"] as? [String: String]) ?? [:]
                        // Reuse the cached message unless its (only mutable) reactions changed.
                        if let cached = self.cache[id], self.rawReactions[id] == raw { return cached }
                        let m = Message(id: id, data: data, cid: self.cid, crypto: Crypto.shared)
                        self.cache[id] = m
                        self.rawReactions[id] = raw
                        return m
                    }
                    // Evict cache entries for messages that no longer exist.
                    let live = Set(snap.documents.map { $0.documentID })
                    self.cache = self.cache.filter { live.contains($0.key) }
                    self.rawReactions = self.rawReactions.filter { live.contains($0.key) }
                    // Drop optimistic copies the server has now confirmed (matched by clientId).
                    let echoed = Set(self.messages.compactMap { $0.clientId })
                    self.pending.removeAll { p in p.clientId.map(echoed.contains) ?? false }
                }
        }
    }

    func stop() {
        listener?.remove(); listener = nil
        convListener?.remove(); convListener = nil
        userListener?.remove(); userListener = nil
    }

    deinit { listener?.remove(); convListener?.remove(); userListener?.remove() }
}
