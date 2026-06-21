import Foundation
import FirebaseAuth
import FirebaseFirestore

// Writes my online/last-active state so the other person sees "online" / "last seen".
enum PresenceService {
    static func set(online: Bool) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try? await Firestore.firestore().collection("users").document(uid).setData([
            "online": online,
            "lastActive": FieldValue.serverTimestamp(),
        ], merge: true)
    }
}
