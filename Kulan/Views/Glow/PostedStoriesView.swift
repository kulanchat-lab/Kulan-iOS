import SwiftUI

/// POSTED STORIES, FULL PAGE — his requirement 6: a header, a Filter button top right, and filter
/// options for My Friends / Custom / Glowers.
///
/// ⚠️ THE FILTER IS OVER THE AUDIENCE A STORY WAS POSTED TO, which is a fact frozen onto the story
/// at post time and never recomputed — the same `audience` label the author's own header shows.
/// That is what makes the filter honest: it groups by what was actually chosen when the story went
/// out, not by who happens to be a glower today. Changing your glow list cannot re-file an old
/// story, for the same reason editing a list cannot reach one.
struct PostedStoriesView: View {
    let uid: String
    var isMe: Bool = false
    var title: String = ""

    /// Explicit, for the private-stored-property rule - see the note in GlowProfileView.
    init(uid: String, isMe: Bool = false, title: String = "") {
        self.uid = uid; self.isMe = isMe; self.title = title
    }

    /// The audiences a story can have been posted to, as the filter offers them. `everyone` is
    /// included because it exists and a filter that cannot show one of the four would hide stories
    /// with no way to find them; his three named ones are the rest.
    enum Filter: String, CaseIterable, Identifiable {
        case all, friends, custom, glowers
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .friends: return "My Friends"
            case .custom: return "Custom"
            case .glowers: return "Glowers"
            }
        }
        /// What it means in one line, his "the filtering behaviour should be clear and easy to
        /// understand" — shown under the option rather than left to be guessed.
        var explain: String {
            switch self {
            case .all: return "Every story you have posted that is still live"
            case .friends: return "Stories visible to your friends"
            case .custom: return "Stories shared with a custom audience"
            case .glowers: return "Stories shared with your Glowers"
            }
        }
        /// ⚠️ MATCHES THE STORY'S OWN LABEL. "everyone" is deliberately counted as a friends-visible
        /// story here: an Everyone story reaches every chat you have accepted AND the profile, so
        /// hiding it from the My Friends filter would be a lie about who can see it.
        func matches(_ audience: String) -> Bool {
            switch self {
            case .all: return true
            case .friends: return audience == "friends" || audience == "everyone"
            case .custom: return audience == "custom"
            case .glowers: return audience == "glowers"
            }
        }
    }

    @State private var loader = PostedStoriesLoader()
    /// The person, for the door below. Fetched with the page rather than passed in, because this
    /// screen can be reached with nothing but a uid.
    @State private var person: UserProfile?
    @State private var filter: Filter = .all
    @State private var showFilters = false
    @Environment(\.dismiss) private var dismiss

    /// ⛔ THE APP'S OWN STORY GRID, NOT A FOURTH ONE — owner, 2026-09-05, item 17: "Posted stories
    /// page: redesign exactly like the image (grid + view counts)." What was here was a mosaic with
    /// square corners on a 3pt gutter, so the same picture came out at one shape here and another
    /// on every other story grid.
    ///
    /// ⚠️ COMPUTED, NOT A STORED `let` WITH A DEFAULT. A stored property's initialiser runs outside
    /// the view's main-actor context, and these Glow screens have already failed the compiler three
    /// times on exactly that class of mistake. `GlowStoriesGridView` builds its columns inside
    /// `body` for the same reason; this is the same thing with a name.
    ///
    /// ⛔ THREE ACROSS, ON HIS CONCEPT IMAGE OF THIS PAGE — 2026-09-09, "make it exactly like this
    /// image". An earlier pass this same day put two here to match the Glowing grid, which was the
    /// honest guess before the picture arrived; the picture settles it at three, with the tighter
    /// gap and side margin that three columns need to breathe.
    ///
    /// ⚠️ This is deliberately NOT `GlowStoryCardView.gutter`. That 16 is the air between two
    /// person-cards on a two-column grid; at three columns it takes a third of the row.
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PostedGrid.gap),
              count: PostedGrid.columns)
    }

    /// The page's grid metrics, from his concept image.
    private enum PostedGrid {
        static let columns: Int = 3
        static let gap: CGFloat = 6
        static let margin: CGFloat = 6
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            // A pushed page is not a tab — see the note in `GlowNotificationsView`.
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                // ⛔ THE FILTER IS THE TITLE — his reference: "Posted stories ⌄", a menu hanging off
                // the heading rather than an icon in the corner. That is better than my first pass
                // for a reason worth keeping: the title then always says WHICH set you are looking
                // at, so a filtered page cannot be mistaken for the whole list. A corner icon puts
                // the state somewhere you have to go looking for.
                ToolbarItem(placement: .principal) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.allCases) { f in
                                // The sentence rides along inside the menu row, so the explanation
                                // he asked for survives losing the sheet.
                                Text(f == .all ? f.title : "\(f.title) — \(f.explain)").tag(f)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter == .all ? "Posted stories" : filter.title)
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .task {
                await loader.load(uid: uid)
                await loader.loadViewCounts(isMe: isMe)
                if !isMe, person == nil { person = await ProfileStore.shared.fetch(uid) }
            }
    }

    /// Open this person's story set. The same two doors the profile's rail uses, and for the same
    /// reason — see `GlowProfileView.openPosted`.
    private func open() {
        if isMe {
            guard let mine = StoriesRepository.shared.mine, !mine.stories.isEmpty else { return }
            StoryDoor.open(mine, among: [mine], from: mine.id, pinned: true, deliveredToMe: true)
        } else {
            let p = GlowPerson(id: uid,
                               name: person?.name ?? title,
                               handle: person?.handle ?? "",
                               photoUrl: person?.photoUrl)
            Task { await GlowStoryOpen.open(p) }
        }
    }

    @ViewBuilder private var content: some View {
        switch loader.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Could not load stories", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") {
                    loader.invalidate()
                    Task { await loader.load(uid: uid, force: true); await loader.loadViewCounts(isMe: isMe) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .loaded(let all):
            let rows = all.filter { filter.matches($0.audience) }
            if rows.isEmpty {
                // ⚠️ TWO DIFFERENT EMPTIES, AND THEY MUST READ DIFFERENTLY. No stories at all is a
                // fact about the account; no stories THROUGH THIS FILTER is a fact about the
                // filter, and offering "Show all" is the way out of a corner the person filtered
                // themselves into.
                if all.isEmpty {
                    ContentUnavailableView("No live stories", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Stories disappear after 24 hours."))
                } else {
                    ContentUnavailableView {
                        Label("Nothing in \(filter.title)", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(filter.explain)
                    } actions: {
                        Button("Show All") { filter = .all }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ScrollView {
                    // Row spacing is the SAME gutter as the columns, so the air between two cards
                    // reads the same in both directions — the rule the Glowing grid already
                    // follows.
                    LazyVGrid(columns: columns, spacing: PostedGrid.gap) {
                        // ⛔ THE CELL OPENS THE STORY — owner, 2026-09-02: "when I click a story
                        // it is not opening". Same omission as the profile's rail: the tile was
                        // drawn and never wired to anything.
                        ForEach(rows) { s in
                            Button { open() } label: { PostedStoryGridTile(story: s) }
                                .buttonStyle(.plain)
                        }
                    }
                    // The tiles run close to the screen's edges in his image, so the margin matches
                    // the gap between them rather than the wide inset a two-column grid takes.
                    .padding(.horizontal, PostedGrid.margin)
                    .padding(.top, 8)
                }
                .refreshable {
                    await loader.load(uid: uid, force: true)
                    await loader.loadViewCounts(isMe: isMe)
                }
            }
        }
    }
}

/// The filter sheet. Rows rather than a segmented control, because each one carries a sentence
/// explaining what it shows — which is his requirement, and does not fit in a segment.
private struct FilterSheet: View {
    @Binding var selection: PostedStoriesView.Filter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(PostedStoriesView.Filter.allCases) { f in
                    Button {
                        selection = f
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.headline).foregroundStyle(.primary)
                                Text(f.explain).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if selection == f {
                                Image(systemName: "checkmark")
                                    .font(.headline).foregroundStyle(GlowStyle.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.font(.headline)
                }
            }
        }
    }
}

/// One cell of the full-page grid: the poster, the view count, and a mark for a video.
///
/// ⛔ THE SAME CARD SHAPE AS `GlowStoryCardView` — owner, 2026-09-05, item 17: "Posted stories
/// page: redesign exactly like the image (grid + view counts)."
///
/// ⚠️ NOT `GlowStoryCardView` ITSELF, ON PURPOSE. That card's whole bottom edge is WHOSE story this
/// is — a name and a ringed face — and this page is one person's own stories, so every tile would
/// carry the same name and the same face repeated down the screen. The SHAPE is shared (aspect,
/// corner, gutter, margin, all read off that type); the thing written on it is different, because
/// the question the page answers is different: not who posted it, but how many people saw it.
private struct PostedStoryGridTile: View {
    let story: PostedStory

    var body: some View {
        Color.clear
            .aspectRatio(GlowStoryCardView.aspect, contentMode: .fit)
            .overlay { StoryImage(url: story.thumbUrl) }
            .overlay(alignment: .bottomLeading) {
                // ⛔ THE VIEW COUNT, WHICH IS HALF OF WHAT HE ASKED FOR. Absent, never zero, when
                // the number is unknown — the count is author-only (`stories/{id}/meta/views` is
                // readable by its owner alone), so somebody else's posted page has no number to
                // show and this draws none rather than a confident 0. That mistake is on the
                // record: `fetchViewSummary`'s own note, and the 2026-08-18 batch where a counter
                // doc saying 0 was trusted over receipts that named a viewer.
                // ⛔ NO CAPSULE, AND A SCRIM INSTEAD — his concept image of this page, 2026-09-09.
                // He reads the count as plain white sitting on the photograph. A gradient along the
                // bottom edge is what keeps it readable over a bright picture, which is the job the
                // capsule was doing and the thing his image does not have.
                //
                // The clearances come down with the corner: 8 is right against an 18pt arc, where
                // 14 was clearance from 34.
                if story.views != nil {
                    LinearGradient(colors: [.black.opacity(0.45), .clear],
                                   startPoint: .bottom, endPoint: .top)
                        .frame(height: 52)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }
                if let v = story.views {
                    Label(GlowCount.short(v), systemImage: "eye.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.leading, 8)
                        .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if story.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        // Same arc clearance as the count, on the corner it sits in.
                        .padding(.trailing, 8)
                        .padding(.top, 8)
                }
            }
            // ⚠️ ONE CLIP, LAST, OVER THE FINISHED TILE — and `compositingGroup()` before it. Both
            // halves are `GlowStoryCardView`'s hard-won rule: without the group the rounded rect is
            // applied per layer as each is drawn, and the layers that miss it are what show up in
            // the corners under the open/close transform. `.clipped()` (a square crop, halfway up
            // the chain) was what stood here.
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: PostedTile.corner, style: .continuous))
    }
}
