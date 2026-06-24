import Foundation
import Observation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

// One photo story. Rules-protected (v1, not E2EE); media is a plain image in Storage.
struct Story: Identifiable, Hashable {
    let id: String
    let authorUid: String
    let createdAt: Date
    let expiresAt: Date
    let mediaUrl: String
    let allowsReplies: Bool
}

// A person's active (unexpired) stories — the unit behind a ring in the row + the viewer.
struct StoryGroup: Identifiable {
    let authorUid: String
    let name: String
    let photoUrl: String?
    var stories: [Story]          // oldest → newest
    var lastViewedAt: Date?
    var isMine: Bool

    var id: String { authorUid }

    // Unseen ⇔ I haven't viewed since the newest story (mirrors Signal's ring logic).
    var hasUnseen: Bool {
        guard let newest = stories.map(\.createdAt).max() else { return false }
        guard let lv = lastViewedAt else { return true }
        return lv < newest
    }
}

@Observable
final class StoriesService {
    static let shared = StoriesService()
    private init() {}

    private let db = Firestore.firestore()
    private var uid: String { Auth.auth().currentUser?.uid ?? "" }

    // Post a photo to "My Status": everyone I've chatted with can see it for 24h.
    func postStory(image: Data) async throws {
        let me = uid
        guard !me.isEmpty else { return }
        let storyId = UUID().uuidString
        let path = "stories/\(storyId).jpg"

        let jpeg = ChatService.downscaledJPEG(image)
        let ref = Storage.storage().reference().child(path)
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        _ = try await ref.putDataAsync(jpeg, metadata: meta)
        let url = try await ref.downloadURL().absoluteString

        // v1 audience = everyone I have a conversation with.
        let recipients = Set(ConversationsRepository.shared.conversations
            .map { $0.otherUid(me) }.filter { !$0.isEmpty })

        try await db.collection("stories").document(storyId).setData([
            "authorUid": me,
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(24 * 3600)),
            "type": "image",
            "mediaPath": path,
            "mediaUrl": url,
            "audience": ["mode": "all", "listId": "my-story"],
            "allowsReplies": true,
            "replyCount": 0,
            "recipientUids": Array(recipients),
        ])
    }

    // Record that I viewed a story: bumps my seen-ring marker + sends a view receipt.
    func markViewed(_ story: Story) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        try? await db.collection("users").document(me)
            .collection("storyContexts").document(story.authorUid)
            .setData(["lastViewedAt": FieldValue.serverTimestamp()], merge: true)
        try? await db.collection("stories").document(story.id)
            .collection("views").document(me)
            .setData(["viewedAt": FieldValue.serverTimestamp()])
    }

    func deleteStory(_ id: String) async {
        try? await db.collection("stories").document(id).delete()
    }
}

// Loads the stories I can see (mine + others' that include me), unexpired, grouped by
// person, with my seen-state attached. On-demand load (refresh on appear) for v1.
@Observable
final class StoriesRepository {
    static let shared = StoriesRepository()
    private init() {}

    private let db = Firestore.firestore()
    var mine: StoryGroup?            // my own story (the "My Status" cell)
    var others: [StoryGroup] = []    // friends' stories, unseen-first

    private func parse(_ docs: [QueryDocumentSnapshot]?) -> [Story] {
        (docs ?? []).compactMap { d in
            let data = d.data()
            guard let author = data["authorUid"] as? String,
                  let url = data["mediaUrl"] as? String,
                  let exp = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
            let created = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            return Story(id: d.documentID, authorUid: author, createdAt: created,
                         expiresAt: exp, mediaUrl: url,
                         allowsReplies: data["allowsReplies"] as? Bool ?? true)
        }
    }

    func load() async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        let now = Date()

        let othersSnap = try? await db.collection("stories")
            .whereField("recipientUids", arrayContains: me).getDocuments()
        let mineSnap = try? await db.collection("stories")
            .whereField("authorUid", isEqualTo: me).getDocuments()
        let ctxSnap = try? await db.collection("users").document(me)
            .collection("storyContexts").getDocuments()

        let all = (parse(othersSnap?.documents) + parse(mineSnap?.documents))
            .filter { $0.expiresAt > now }

        // My per-author "last viewed" markers.
        var lastViewed: [String: Date] = [:]
        for d in ctxSnap?.documents ?? [] {
            if let ts = (d.data()["lastViewedAt"] as? Timestamp)?.dateValue() { lastViewed[d.documentID] = ts }
        }

        let convs = ConversationsRepository.shared.conversations
        func display(_ uid: String) -> (String, String?) {
            if uid == me {
                return (ProfileStore.shared.me?.name ?? "You", ProfileStore.shared.me?.photoUrl)
            }
            if let c = convs.first(where: { $0.otherUid(me) == uid }) {
                return (c.name(for: me), c.photoUrl(for: me))
            }
            return ("", nil)
        }

        var myGroup: StoryGroup?
        var groups: [StoryGroup] = []
        for (author, list) in Dictionary(grouping: all, by: { $0.authorUid }) {
            let sorted = list.sorted { $0.createdAt < $1.createdAt }
            let (name, photo) = display(author)
            let g = StoryGroup(authorUid: author, name: name, photoUrl: photo,
                               stories: sorted, lastViewedAt: lastViewed[author], isMine: author == me)
            if author == me { myGroup = g } else { groups.append(g) }
        }
        // Unseen first, then by most-recent story.
        groups.sort {
            if $0.hasUnseen != $1.hasUnseen { return $0.hasUnseen }
            return ($0.stories.last?.createdAt ?? .distantPast) > ($1.stories.last?.createdAt ?? .distantPast)
        }

        await MainActor.run { self.mine = myGroup; self.others = groups }
    }
}
