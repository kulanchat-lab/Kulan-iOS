import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

/// My profile + lookups for other users. The header avatar reads `me` (loaded
/// once at launch) — native TabView keeps it mounted, so no re-fetch/blink.
@Observable
final class ProfileStore {
    static let shared = ProfileStore()
    private init() {}

    private let db = Firestore.firestore()
    var me: UserProfile?

    func loadMine() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        me = await fetch(uid)
    }

    func fetch(_ uid: String) async -> UserProfile? {
        guard !uid.isEmpty else { return nil }
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            guard let data = snap.data() else { return nil }
            return UserProfile(id: uid, data: data)
        } catch {
            print("profile fetch failed:", error)
            return nil
        }
    }

    func updateProfile(name: String, handle: String) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let h = handle.trimmingCharacters(in: .whitespaces)
        try await db.collection("users").document(uid).setData([
            "name": name.trimmingCharacters(in: .whitespaces),
            "handle": h,
            "handleLower": h.lowercased(),
        ], merge: true)
        me = await fetch(uid)
    }

    /// Upload a profile photo. Native Data -> Firebase Storage (no Hermes blob
    /// crash). Propagates the URL to the user doc + each conversation's photo map.
    func uploadPhoto(_ data: Data) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = Storage.storage().reference().child("profiles/\(uid).jpg")
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(data, metadata: meta)
        let url = try await ref.downloadURL().absoluteString

        try await db.collection("users").document(uid).setData(["photoUrl": url], merge: true)

        let snap = try await db.collection("conversations")
            .whereField("users", arrayContains: uid).getDocuments()
        let batch = db.batch()
        for d in snap.documents { batch.updateData(["photos.\(uid)": url], forDocument: d.reference) }
        try await batch.commit()

        me = await fetch(uid)
    }
}
