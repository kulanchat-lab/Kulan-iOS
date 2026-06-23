import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

/// Live messages for one conversation. Loads a bounded WINDOW (most-recent page)
/// with a live listener, pages OLDER messages in on scroll-to-top, and reuses
/// already-decrypted messages so each snapshot only decrypts new/changed docs.
@Observable
final class ThreadRepository {
    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var convListener: ListenerRegistration?
    private var userListener: ListenerRegistration?
    let cid: String

    private let pageSize = 40

    var messages: [Message] = []           // confirmed server messages (ascending)
    var pending: [Message] = []            // optimistic, not yet echoed back
    var canLoadOlder = true
    var loadingOlder = false

    // Decrypt cache: id -> built message, plus the raw (encrypted) reactions we last
    // saw, so we only rebuild a message when its one mutable field actually changes.
    private var byId: [String: Message] = [:]
    private var rawReactions: [String: [String: String]] = [:]
    private var oldestDoc: DocumentSnapshot?   // cursor for paging older
    private var didInitialLoad = false

    var otherTyping = false
    var otherOnline = false
    var otherLastActive: Date?
    var otherLastReadMillis: Double = 0
    var iBlocked = false
    private var otherUid = ""
    private var myBlockedAtMillis: Double = 0   // hide the other's messages after this
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
        otherUid = other
        stop()
        // Conversation doc: the other person's typing flag + their read timestamp.
        convListener = db.collection("conversations").document(cid)
            .addSnapshotListener { [weak self] snap, _ in
                guard let self else { return }
                let d = snap?.data()
                self.otherTyping = (d?["typing"] as? [String: Any])?[other] as? Bool ?? false
                self.iBlocked = (d?["blockedBy"] as? [String: Any])?[uid] as? Bool ?? false
                self.myBlockedAtMillis = ((d?["blockedAt"] as? [String: Any])?[uid] as? NSNumber)?.doubleValue ?? 0
                self.pinnedMessageId = d?["pinnedMessageId"] as? String ?? ""
                if let ts = (d?["lastRead"] as? [String: Any])?[other] as? Timestamp {
                    self.otherLastReadMillis = ts.dateValue().timeIntervalSince1970 * 1000
                }
                self.rebuild()   // re-apply the block filter when block state changes
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
            // Live listener over the most-recent page only (bounds first paint, memory,
            // and Firestore reads regardless of how long the history is).
            listener = db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt", descending: true)
                .limit(to: pageSize)
                .addSnapshotListener { [weak self] snap, _ in
                    guard let self, let snap else { return }
                    // Don't blank an open thread on an empty offline snapshot.
                    if snap.metadata.isFromCache && snap.documents.isEmpty && !self.messages.isEmpty { return }
                    self.applyLiveSnapshot(snap.documents)
                }
        }
    }

    // Build a message, reusing the cached copy unless its reactions changed.
    @discardableResult
    private func buildCached(_ doc: QueryDocumentSnapshot) -> Message {
        let id = doc.documentID, data = doc.data()
        let raw = (data["reactions"] as? [String: String]) ?? [:]
        if let cached = byId[id], rawReactions[id] == raw { return cached }
        let m = Message(id: id, data: data, cid: cid, crypto: Crypto.shared)
        byId[id] = m
        rawReactions[id] = raw
        return m
    }

    // Apply the live (recent-window) snapshot: refresh/insert the window's messages,
    // reconcile deletes within the window's time range, keep paged-older messages.
    private func applyLiveSnapshot(_ docs: [QueryDocumentSnapshot]) {
        var windowIds = Set<String>()
        for doc in docs { buildCached(doc); windowIds.insert(doc.documentID) }
        // A doc missing from the window but newer than its oldest edge was deleted.
        if let oldest = docs.last, let cutoff = (oldest.data()["createdAt"] as? Timestamp)?.dateValue() {
            for (id, m) in byId where m.createdAt >= cutoff && !windowIds.contains(id) {
                byId.removeValue(forKey: id); rawReactions.removeValue(forKey: id)
            }
        }
        if oldestDoc == nil { oldestDoc = docs.last }
        if !didInitialLoad {
            didInitialLoad = true
            if docs.count < pageSize { canLoadOlder = false }   // short first page => no history
        }
        rebuild()
        let echoed = Set(byId.values.compactMap { $0.clientId })
        pending.removeAll { p in p.clientId.map(echoed.contains) ?? false }
    }

    private func rebuild() {
        let cutoff = myBlockedAtMillis
        messages = byId.values
            // Silent block: hide the other person's messages sent AFTER I blocked them.
            .filter { m in
                !(iBlocked && m.authorId == otherUid && cutoff > 0
                  && m.createdAt.timeIntervalSince1970 * 1000 > cutoff)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Page in the next older window (called on scroll-to-top). `completion` runs after
    /// the list updates so the view can restore the scroll anchor (no jump).
    func loadOlder(completion: @escaping () -> Void = {}) {
        guard canLoadOlder, !loadingOlder, let cursor = oldestDoc else { completion(); return }
        loadingOlder = true
        db.collection("conversations").document(cid).collection("messages")
            .order(by: "createdAt", descending: true)
            .start(afterDocument: cursor)
            .limit(to: pageSize)
            .getDocuments { [weak self] snap, _ in
                guard let self else { return }
                let docs = snap?.documents ?? []
                for doc in docs { self.buildCached(doc) }
                if let last = docs.last { self.oldestDoc = last }
                if docs.count < self.pageSize { self.canLoadOlder = false }
                self.loadingOlder = false
                self.rebuild()
                completion()
            }
    }

    func stop() {
        listener?.remove(); listener = nil
        convListener?.remove(); convListener = nil
        userListener?.remove(); userListener = nil
    }

    deinit { listener?.remove(); convListener?.remove(); userListener?.remove() }
}
