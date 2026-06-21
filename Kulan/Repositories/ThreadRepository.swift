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
    let cid: String

    var messages: [Message] = []

    init(cid: String) { self.cid = cid }

    func start() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let other = cid.split(separator: "_").map(String.init).first { $0 != uid } ?? ""
        stop()
        Task {
            try? await Crypto.shared.ensureReady()
            _ = await Crypto.shared.preloadKey(other)
            listener = db.collection("conversations").document(cid).collection("messages")
                .order(by: "createdAt")
                .addSnapshotListener { [weak self] snap, _ in
                    guard let self, let snap else { return }
                    // Don't blank an open thread on an empty offline snapshot.
                    if snap.metadata.isFromCache && snap.documents.isEmpty && !self.messages.isEmpty { return }
                    self.messages = snap.documents.map {
                        Message(id: $0.documentID, data: $0.data(), cid: self.cid, crypto: Crypto.shared)
                    }
                }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    deinit { listener?.remove() }
}
