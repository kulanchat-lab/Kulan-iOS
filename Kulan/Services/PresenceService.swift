import Foundation
import FirebaseAuth
import FirebaseFirestore

// Writes my online/last-active state so the other person sees "online" / "last seen".
enum PresenceService {
    static func set(online: Bool) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Privacy: if last-seen sharing is off, always publish offline (never reveal activity).
        let share = UserDefaults.standard.object(forKey: "shareLastSeen") as? Bool ?? true
        try? await Firestore.firestore().collection("users").document(uid).setData([
            "online": share ? online : false,
            "lastActive": FieldValue.serverTimestamp(),
        ], merge: true)
    }
}
