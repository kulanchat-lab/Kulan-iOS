import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore

// One row in the call history. Direction is derived by the viewer (callerUid == me).
struct CallEntry: Identifiable, Hashable {
    let id: String          // call message doc id
    let cid: String
    let name: String
    let photoUrl: String?
    let otherUid: String
    let callerUid: String
    let outcome: String     // answered | missed
    let durationSec: Int
    let date: Date

    var mine: Bool { callerUid == (Auth.auth().currentUser?.uid ?? "") }
    var missed: Bool { outcome == "missed" }
}

// Aggregates call records across all of my conversations into one history list.
// Each per-conversation query is an equality filter (type == "call"), which uses the
// automatic single-field index — no composite index to deploy. Sorted client-side.
@Observable
final class CallsRepository {
    static let shared = CallsRepository()
    private init() {}

    private let db = Firestore.firestore()
    var calls: [CallEntry] = []
    var loading = false
    var hasLoaded = false   // false until the first load finishes -> drives the skeleton
    private var lastLoadedAt: Date?

    // force: true bypasses the 30s TTL (pull-to-refresh). Normal tab-switch passes false so we
    // don't re-fire N concurrent Firestore queries every time the Calls tab becomes visible.
    func load(force: Bool = false) async {
        if !force, hasLoaded, let last = lastLoadedAt, Date().timeIntervalSince(last) < 30 { return }
        guard let me = Auth.auth().currentUser?.uid else { return }
        await MainActor.run { loading = true }
        let database = db

        let convSnap = try? await database.collection("conversations")
            .whereField("users", arrayContains: me).getDocuments()
        let convs = (convSnap?.documents ?? []).map { Conversation(id: $0.documentID, data: $0.data()) }

        // Fetch every chat's call records CONCURRENTLY (was sequential = N round-trips in
        // series). Each task builds its own CallEntry list off-main; results merged after.
        var all: [CallEntry] = []
        await withTaskGroup(of: [CallEntry].self) { group in
            for c in convs {
                group.addTask {
                    let other = c.otherUid(me), name = c.name(for: me), photo = c.photoUrl(for: me)
                    guard let snap = try? await database.collection("conversations").document(c.id)
                        .collection("messages").whereField("type", isEqualTo: "call").getDocuments()
                    else { return [] }
                    return snap.documents.map { d in
                        let data = d.data()
                        let ts = data["createdAt"] as? Timestamp
                        return CallEntry(
                            id: d.documentID, cid: c.id,
                            name: name, photoUrl: photo, otherUid: other,
                            callerUid: data["callerUid"] as? String ?? "",
                            outcome: data["callOutcome"] as? String ?? "answered",
                            durationSec: (data["callDuration"] as? NSNumber)?.intValue ?? 0,
                            date: ts?.dateValue() ?? Date(timeIntervalSince1970: 0))
                    }
                }
            }
            for await chunk in group { all.append(contentsOf: chunk) }
        }
        all.sort { $0.date > $1.date }
        await MainActor.run { self.calls = all; self.loading = false; self.hasLoaded = true; self.lastLoadedAt = Date() }
    }

    // Delete one call record (the underlying call message doc).
    func delete(_ entry: CallEntry) async {
        try? await db.collection("conversations").document(entry.cid)
            .collection("messages").document(entry.id).delete()
        await MainActor.run { calls.removeAll { $0.id == entry.id } }
    }

    // Delete several selected call records — single batched write instead of N round-trips.
    func delete(ids: Set<String>) async {
        let targets = await MainActor.run { calls.filter { ids.contains($0.id) } }
        let batch = db.batch()
        for c in targets {
            let ref = db.collection("conversations").document(c.cid)
                .collection("messages").document(c.id)
            batch.deleteDocument(ref)
        }
        try? await batch.commit()
        await MainActor.run { calls.removeAll { ids.contains($0.id) } }
    }
}
