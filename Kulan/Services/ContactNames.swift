import Foundation

// Local, per-device custom display names for contacts. Kulan has no server-side address book
// (and no phone numbers) — accounts are username-based — so when you add a contact with a
// First/Last name, we store that name here keyed by their uid and let it override the profile
// name in the chat list + headers. Purely local; never sent anywhere.
enum ContactNames {
    private static let key = "contactCustomNames"

    private static var map: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func name(for uid: String) -> String? {
        let n = map[uid]?.trimmingCharacters(in: .whitespaces)
        return (n?.isEmpty == false) ? n : nil
    }

    static func set(_ name: String, for uid: String) {
        var m = map
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { m.removeValue(forKey: uid) } else { m[uid] = trimmed }
        map = m
    }
}
