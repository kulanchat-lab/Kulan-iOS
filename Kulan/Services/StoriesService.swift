import Foundation
import Observation
import UIKit
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

    // Optimistic upload state — drives the "Uploading…" indicator + spinner ring in the story row.
    var uploading = false
    var uploadingImage: UIImage?
    private var uploadTask: Task<Void, Never>?

    // Fire-and-forget post: pop back to chat immediately, upload in the background, show progress.
    @MainActor func postStoryBackground(image: Data, excluded: Set<String> = [], included: Set<String> = []) {
        uploadTask?.cancel()
        uploadingImage = UIImage(data: image)
        uploading = true
        uploadTask = Task {
            do { try await postStory(image: image, excluded: excluded, included: included) }
            catch { /* swallow; uploadingImage clears below either way */ }
            await MainActor.run { uploading = false; uploadingImage = nil; uploadTask = nil }
            await StoriesRepository.shared.load(force: true)   // just posted → bypass the throttle
        }
    }

    @MainActor func cancelUpload() {
        uploadTask?.cancel(); uploadTask = nil
        uploading = false; uploadingImage = nil
    }

    // Post a photo to "My Status": chosen audience can see it for 24h.
    func postStory(image: Data, expiryHours: Double = 24,
                   excluded: Set<String> = [], included: Set<String> = []) async throws {
        let me = uid
        guard !me.isEmpty else { return }
        let storyId = UUID().uuidString
        let path = "stories/\(storyId)/photo.jpg"   // {storyId}/ segment so Storage rules can audience-scope reads

        // Snapshot contacts on the MAIN actor (live-mutated there). Audience:
        //  • included non-empty -> only those; • excluded non-empty -> everyone minus those; • else everyone.
        let allContacts = await MainActor.run {
            Set(ConversationsRepository.shared.conversations
                .map { $0.otherUid(me) }.filter { !$0.isEmpty })
        }
        let recipients: Set<String>
        let mode: String
        if !included.isEmpty { recipients = included.intersection(allContacts); mode = "only" }
        else if !excluded.isEmpty { recipients = allContacts.subtracting(excluded); mode = "except" }
        else { recipients = allContacts; mode = "all" }

        // Create the story doc FIRST (mediaUrl filled in after upload). The Storage READ
        // rule for downloadURL() checks this doc's authorUid, so it must exist before we
        // resolve the URL — otherwise getDownloadURL() is denied and the post fails.
        let docRef = db.collection("stories").document(storyId)
        try await docRef.setData([
            "authorUid": me,
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: Date().addingTimeInterval(expiryHours * 3600)),
            "type": "image",
            "mediaPath": path,
            "mediaUrl": "",
            "audience": ["mode": mode, "listId": "my-story"],
            "allowsReplies": true,
            "replyCount": 0,
            "recipientUids": Array(recipients),
        ])

        // Upload the image, then resolve + persist its download URL. If anything fails,
        // remove the doc so we never leave a story with no image.
        do {
            let jpeg = ChatService.downscaledJPEG(image)
            let ref = Storage.storage().reference().child(path)
            let meta = StorageMetadata(); meta.contentType = "image/jpeg"
            _ = try await ref.putDataAsync(jpeg, metadata: meta)
            let url = try await ref.downloadURL().absoluteString
            try await docRef.updateData(["mediaUrl": url])
        } catch {
            try? await docRef.delete()
            throw error
        }
    }

    // Record that I viewed a story: always bump my own seen-ring marker; only send a
    // view receipt (so the author sees I viewed) if I have view receipts ON.
    func markViewed(_ story: Story) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        try? await db.collection("users").document(me)
            .collection("storyContexts").document(story.authorUid)
            .setData(["lastViewedAt": FieldValue.serverTimestamp()], merge: true)

        let receiptsOn = UserDefaults.standard.object(forKey: "storyViewReceipts") as? Bool ?? true
        if receiptsOn {
            try? await db.collection("stories").document(story.id)
                .collection("views").document(me)
                .setData(["viewedAt": FieldValue.serverTimestamp()])
        }
    }

    func deleteStory(_ id: String) async {
        try? await db.collection("stories").document(id).delete()
    }

    /// Flag a story for review (App Store 1.2 — abuse reporting).
    func reportStory(_ story: Story) async {
        guard !uid.isEmpty else { return }
        try? await db.collection("reports").addDocument(data: [
            "type": "story",
            "storyId": story.id,
            "authorUid": story.authorUid,
            "reporter": uid,
            "createdAt": FieldValue.serverTimestamp(),
        ])
    }

    /// Delete EVERY story I've posted. Called on account deletion so nothing I shared
    /// stays visible after I'm gone (App Store 5.1.1(v) — deletion must remove my data).
    /// Removes the Storage image first (while the doc still exists, so the rules' author
    /// check passes), then the story doc itself.
    func deleteAllMine() async {
        let me = uid
        guard !me.isEmpty,
              let snap = try? await db.collection("stories")
                  .whereField("authorUid", isEqualTo: me).getDocuments() else { return }
        for d in snap.documents {
            if let path = d.data()["mediaPath"] as? String {
                try? await Storage.storage().reference().child(path).delete()
            }
            try? await d.reference.delete()
        }
    }
}

// Loads the stories I can see (mine + others' that include me), unexpired, grouped by
// person, with my seen-state attached. On-demand load (refresh on appear) for v1.
@Observable
final class StoriesRepository {
    static let shared = StoriesRepository()
    private init() {}

    private let db = Firestore.firestore()
    private var lastLoadAt: Date?    // throttle: skip reloads within 20s unless forced
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

    func load(force: Bool = false) async {
        guard let me = Auth.auth().currentUser?.uid else { return }
        // Throttle: ChatsView re-appears often; skip a reload within 20s unless forced (e.g. post-upload).
        if !force, let last = lastLoadAt, Date().timeIntervalSince(last) < 20 { return }
        lastLoadAt = Date()
        let now = Date()

        // Fire the three reads CONCURRENTLY (was sequential = 3 serial round-trips).
        async let othersSnapT = db.collection("stories").whereField("recipientUids", arrayContains: me).getDocuments()
        async let mineSnapT = db.collection("stories").whereField("authorUid", isEqualTo: me).getDocuments()
        async let ctxSnapT = db.collection("users").document(me).collection("storyContexts").getDocuments()
        let othersSnap = try? await othersSnapT
        let mineSnap = try? await mineSnapT
        let ctxSnap = try? await ctxSnapT

        let all = (parse(othersSnap?.documents) + parse(mineSnap?.documents))
            .filter { $0.expiresAt > now }

        // My per-author "last viewed" markers.
        var lastViewed: [String: Date] = [:]
        for d in ctxSnap?.documents ?? [] {
            if let ts = (d.data()["lastViewedAt"] as? Timestamp)?.dateValue() { lastViewed[d.documentID] = ts }
        }

        // Snapshot @Observable singletons on the main actor (they're mutated there by
        // live listeners) — never read them from this background context directly.
        let (convs, myName, myPhoto) = await MainActor.run {
            (ConversationsRepository.shared.conversations,
             ProfileStore.shared.me?.name ?? "You",
             ProfileStore.shared.me?.photoUrl)
        }
        func display(_ uid: String) -> (String, String?) {
            if uid == me { return (myName, myPhoto) }
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
