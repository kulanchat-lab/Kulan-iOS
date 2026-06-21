import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

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
}
