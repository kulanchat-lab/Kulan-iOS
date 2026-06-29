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
    // Applies to my own story too now: colorful until I open it (then markSeenLocally greys it).
    var hasUnseen: Bool {
        guard let newest = stories.map(\.createdAt).max() else { return false }
        guard let lv = lastViewedAt else { return true }
        return lv < newest
    }
}

// One viewer of my story, for the "Seen by" sheet.
struct StoryViewerInfo: Identifiable {
    let id: String        // viewer uid
    let name: String
    let photoUrl: String?
    let viewedAt: Date
    let reaction: String?
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
    var uploadError: String?   // set when a post fails so the UI can show it (was swallowed → "dead silent")
    private var uploadTask: Task<Void, Never>?

    // Fire-and-forget post: pop back to chat immediately, upload in the background, show progress.
    @MainActor func postStoryBackground(image: Data, excluded: Set<String> = [], included: Set<String> = []) {
        uploadTask?.cancel()
        uploadingImage = UIImage(data: image)
        uploading = true
        uploadTask = Task {
            var failure: String?
            do { try await postStory(image: image, excluded: excluded, included: included) }
            catch { failure = error.localizedDescription }   // surface it instead of dying silently
            // On success, pull the new story into the repo BEFORE clearing the placeholder — otherwise the
            // card briefly shows the OLD latest story (stale-cover flicker) then rebuilds again. Reloading
            // first lets the "Uploading…" card morph straight into the final My Story card (one transition).
            if failure == nil { await StoriesRepository.shared.load(force: true) }
            await MainActor.run { uploading = false; uploadingImage = nil; uploadTask = nil; uploadError = failure }
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
                .filter { !$0.isGroup && !$0.leaksBlocked(me) }   // 1:1 contacts only (a group's otherUid is an
                .map { $0.otherUid(me) }.filter { !$0.isEmpty })  // arbitrary member → leak); skip blocked (C3)
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
            // Warm the cache the My Story card reads from (DiskImageCache), so the final card shows the
            // image instantly as the "Uploading…" placeholder morphs into it — no blank-then-fetch.
            if let img = UIImage(data: jpeg) { DiskImageCache.shared.store(img, data: jpeg, for: url) }
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

    // Set my reaction emoji on my view receipt (shows in the author's "Seen by" list).
    func setStoryReaction(_ story: Story, emoji: String) async {
        let me = uid
        guard !me.isEmpty, story.authorUid != me else { return }
        let receiptsOn = UserDefaults.standard.object(forKey: "storyViewReceipts") as? Bool ?? true
        guard receiptsOn else { return }
        try? await db.collection("stories").document(story.id)
            .collection("views").document(me)
            .setData(["viewedAt": FieldValue.serverTimestamp(), "reaction": emoji], merge: true)
    }

    // Who viewed a story I posted (author-only per rules) → for the "Seen by" sheet.
    func fetchViewers(storyId: String) async -> [StoryViewerInfo] {
        guard !uid.isEmpty else { return [] }
        let snap = try? await db.collection("stories").document(storyId).collection("views").getDocuments()
        let docs = snap?.documents ?? []
        let (convs, me) = await MainActor.run { (ConversationsRepository.shared.conversations, uid) }
        return docs.map { d in
            let u = d.documentID
            let c = convs.first { $0.otherUid(me) == u }
            return StoryViewerInfo(
                id: u,
                name: c?.name(for: me) ?? "Someone",
                photoUrl: c?.photoUrl(for: me),
                viewedAt: (d.data()["viewedAt"] as? Timestamp)?.dateValue() ?? Date(),
                reaction: d.data()["reaction"] as? String
            )
        }.sorted { $0.viewedAt > $1.viewedAt }
    }

    func deleteStory(_ id: String) async {
        // Delete the Storage media FIRST (deterministic path), then the doc — else an early
        // delete (before expiry) leaks the image forever (cleanup only handles EXPIRED docs).
        try? await Storage.storage().reference().child("stories/\(id)/photo.jpg").delete()
        try? await db.collection("stories").document(id).delete()
    }

    /// Flag a story for review (App Store 1.2 — abuse reporting).
    func reportStory(_ story: Story) async {
        guard !uid.isEmpty else { return }
        try? await db.collection("reports").addDocument(data: [
            "type": "story",
            "storyId": story.id,
            "authorUid": story.authorUid,
            "reporterUid": uid,   // the rule requires reporterUid (was "reporter" → create denied)
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
                  let url = data["mediaUrl"] as? String, !url.isEmpty,   // skip the pre-upload window (empty URL froze the viewer)
                  let exp = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
            let created = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
            return Story(id: d.documentID, authorUid: author, createdAt: created,
                         expiresAt: exp, mediaUrl: url,
                         allowsReplies: data["allowsReplies"] as? Bool ?? true)
        }
    }

    // Optimistically clear the unseen ring the instant a bucket is viewed, so it doesn't stay
    // "unseen" while the serverTimestamp write races the forced reload (H8).
    @MainActor func markSeenLocally(_ authorUid: String) {
        let now = Date()
        if let i = others.firstIndex(where: { $0.authorUid == authorUid }) { others[i].lastViewedAt = now }
        if mine?.authorUid == authorUid { mine?.lastViewedAt = now }
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

        // Don't show stories from anyone in a blocked relationship (C3, read side).
        let blockedAuthors = Set(convs.filter { $0.leaksBlocked(me) }.map { $0.otherUid(me) })

        var myGroup: StoryGroup?
        var groups: [StoryGroup] = []
        for (author, list) in Dictionary(grouping: all, by: { $0.authorUid }) {
            let sorted = list.sorted { $0.createdAt < $1.createdAt }
            let (name, photo) = display(author)
            let g = StoryGroup(authorUid: author, name: name, photoUrl: photo,
                               stories: sorted, lastViewedAt: lastViewed[author], isMine: author == me)
            if author == me { myGroup = g }
            else if !blockedAuthors.contains(author) { groups.append(g) }
        }
        if Self.injectDemoStories { groups.append(contentsOf: Self.demoGroups(now: now)) }   // TEMP test data

        // Unseen first, then by most-recent story.
        groups.sort {
            if $0.hasUnseen != $1.hasUnseen { return $0.hasUnseen }
            return ($0.stories.last?.createdAt ?? .distantPast) > ($1.stories.last?.createdAt ?? .distantPast)
        }

        await MainActor.run { self.mine = myGroup; self.others = groups }
    }

    // ===== TEMPORARY demo stories (real images) for testing the viewer/carousel/rings =====
    // Flip `injectDemoStories` to false (or delete this block) before production.
    static let injectDemoStories = true
    static func demoGroups(now: Date) -> [StoryGroup] {
        func story(_ uid: String, _ n: Int, _ seed: String) -> Story {
            Story(id: "demo_\(uid)_\(n)", authorUid: uid,
                  createdAt: now.addingTimeInterval(Double(-3600 * (5 - n))),   // a few hours apart
                  expiresAt: now.addingTimeInterval(3600 * 20),
                  mediaUrl: "https://picsum.photos/seed/\(seed)/1080/1920", allowsReplies: true)
        }
        func group(_ uid: String, _ name: String, _ avatar: Int, _ seeds: [String]) -> StoryGroup {
            StoryGroup(authorUid: uid, name: name, photoUrl: "https://i.pravatar.cc/150?img=\(avatar)",
                       stories: seeds.enumerated().map { story(uid, $0.offset + 1, $0.element) },
                       lastViewedAt: nil, isMine: false)
        }
        return [
            group("demo_alex",  "Alex (demo)",  12, ["alexa", "alexb", "alexc"]),
            group("demo_maya",  "Maya (demo)",  45, ["mayaa", "mayab"]),
            group("demo_sam",   "Sam (demo)",   33, ["sama", "samb", "samc", "samd"]),
            group("demo_lena",  "Lena (demo)",  5,  ["lenaa"]),
            group("demo_omar",  "Omar (demo)",  68, ["omara", "omarb", "omarc", "omard", "omare"]),
            group("demo_nina",  "Nina (demo)",  47, ["ninaa", "ninab"]),
            group("demo_jay",   "Jay (demo)",   15, ["jaya", "jayb", "jayc"]),
            group("demo_zoe",   "Zoe (demo)",   9,  ["zoea", "zoeb", "zoec", "zoed"]),
            group("demo_kofi",  "Kofi (demo)",  60, ["kofia", "kofib"]),
        ]
    }
}
