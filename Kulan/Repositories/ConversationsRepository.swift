import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

/// Live chat list. Native Firestore disk persistence handles offline/cold-start,
/// so there is no manual AsyncStorage cache to maintain.
@Observable
final class ConversationsRepository {
    static let shared = ConversationsRepository()
    private init() {}

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    var conversations: [Conversation] = []

    func start() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        stop()
        Task {
            try? await Crypto.shared.ensureReady()
            listener = db.collection("conversations")
                .whereField("users", arrayContains: uid)
                .addSnapshotListener { [weak self] snap, error in
                    guard let self, let snap else {
                        if let error { print("conversations listen error:", error) }
                        return
                    }
                    // Offline cold-start: ignore an empty cached snapshot so the
                    // last-known chats stay visible (parity with the RN fromCache guard).
                    if snap.metadata.isFromCache && snap.documents.isEmpty { return }

                    var convs = snap.documents.map { Conversation(id: $0.documentID, data: $0.data()) }
                    convs.sort { $0.updatedAtMillis > $1.updatedAtMillis }
                    self.conversations = convs

                    // Warm recipient public keys so last-message previews can decrypt.
                    Task {
                        for c in convs { _ = await Crypto.shared.preloadKey(c.otherUid(uid)) }
                    }
                }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }
}
