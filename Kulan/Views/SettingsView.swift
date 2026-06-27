import SwiftUI
import PhotosUI
import UIKit
import FirebaseAuth
import FirebaseFirestore

// Parent settings — profile cell on top, then grouped rows that push to dedicated
// sub-screens (the Signal/Telegram structure), built our way with native List.
struct SettingsView: View {
    var onSignOut: () -> Void
    var asTab = false   // true when shown as a bottom tab (no "Done" — nothing to dismiss)
    init(onSignOut: @escaping () -> Void, asTab: Bool = false) {
        self.onSignOut = onSignOut
        self.asTab = asTab
    }

    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @State private var showEdit = false
    @State private var showQR = false

    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Kulan." : "Chat with me on Kulan — my username is @\(h)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showEdit = true } label: { profileHeader }
                        .buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)

                Section {
                    NavigationLink { AccountSettingsView(onSignOut: onSignOut) } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                    NavigationLink { MyProfileView() } label: {
                        Label("My Profile", systemImage: "person.text.rectangle")
                    }
                    NavigationLink { DevicesView() } label: {
                        Label("Linked Devices", systemImage: "laptopcomputer.and.iphone")
                    }
                }

                Section {
                    NavigationLink { NotificationsSettingsView() } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    NavigationLink { AppearanceSettingsView() } label: {
                        Label("Appearance", systemImage: "paintbrush")
                    }
                    NavigationLink { StorySettingsView() } label: {
                        Label("Stories", systemImage: "circle.dashed")
                    }
                    NavigationLink { PrivacySettingsView() } label: {
                        Label("Privacy & Security", systemImage: "lock.shield")
                    }
                }

                Section {
                    Button { showQR = true } label: { Label("My QR Code", systemImage: "qrcode") }
                    ShareLink(item: inviteText) { Label("Invite Friends", systemImage: "person.badge.plus") }
                    NavigationLink { AboutView() } label: {
                        Label("Help & About", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .listSectionSpacing(.compact)   // tighten the dead space between blocks
            .contentMargins(.top, 4, for: .scrollContent)   // remove the big gap above the avatar
            .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showQR = true } label: { Image(systemName: "qrcode") }.tint(.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { showEdit = true }.tint(.primary)
                }
                if !asTab {
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                }
            }
            .sheet(isPresented: $showEdit) { EditProfileView() }
            .sheet(isPresented: $showQR) { MyQRView() }
        }
    }

    // Centered profile header (mockup style): big avatar, name, @handle. Tap to edit.
    private var profileHeader: some View {
        VStack(spacing: 8) {
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 96)
            Text(profile.me?.name ?? "You")
                .font(.title2.weight(.bold)).foregroundStyle(.primary)
            if let h = profile.me?.handle, !h.isEmpty {
                Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }
}

// MARK: - My Profile

// Your own profile, shown the way other people see it (hero avatar, name, @handle, bio),
// with your own Stories section below. Edit lives in the top-right (opens EditProfileView).
struct MyProfileView: View {
    private var profile = ProfileStore.shared
    @State private var stories = StoriesRepository.shared
    @State private var viewerGroup: StoryGroup?
    @State private var showEdit = false
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var cardColor: Color { dark ? Color(hex: 0x1C1C1E) : Color(hex: 0xF2F2F7) }
    private var title: String {
        if let h = profile.me?.handle, !h.isEmpty { return "@\(h)" }
        return profile.me?.name ?? "My Profile"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                if let about = profile.me?.about, !about.isEmpty { bioCard(about) }
                storiesSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Edit") { showEdit = true }.tint(.primary) }
        }
        .sheet(isPresented: $showEdit) { EditProfileView() }
        .task { await stories.load() }
        .fullScreenCover(item: $viewerGroup) { g in
            StoryViewer(group: g) { viewerGroup = nil; Task { await stories.load() } }
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 96)
            Text(profile.me?.name ?? "You").font(.title.weight(.bold))
            if let h = profile.me?.handle, !h.isEmpty {
                Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func bioCard(_ about: String) -> some View {
        Text(about).font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var storiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My Stories").font(.headline)
            if let mine = stories.mine, !mine.stories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mine.stories) { s in
                            AsyncImage(url: URL(string: s.mediaUrl)) { p in
                                if let img = p.image { img.resizable().scaledToFill() }
                                else { Color.secondary.opacity(0.2) }
                            }
                            .frame(width: 92, height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { viewerGroup = mine }
                        }
                    }
                }
            } else {
                Text("You have no active stories.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sub-pages

struct AccountSettingsView: View {
    var onSignOut: () -> Void
    init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @State private var showDelete = false
    @State private var showSignOut = false
    @State private var working = false
    @State private var exporting = false
    @State private var exportFile: ExportFile?

    var body: some View {
        List {
            // Profile header (native grouped, clear background).
            Section {
                VStack(spacing: 8) {
                    AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 84)
                    Text(profile.me?.name ?? "You").font(.title2.weight(.bold))
                    if let h = profile.me?.handle, !h.isEmpty {
                        Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section("Account") {
                LabeledContent("Username", value: profile.me.map { "@\($0.handle)" } ?? "—")
                LabeledContent("Account ID", value: String((AuthService.shared.uid ?? "").prefix(12)) + "…")
            }

            Section {
                Button { Task { await exportData() } } label: {
                    HStack {
                        Label("Export My Data", systemImage: "square.and.arrow.up")
                        Spacer()
                        if exporting { ProgressView() }
                    }
                }
                .tint(.primary)
                .disabled(exporting)
            } footer: {
                Text("Saves your profile and all chats to a text file you can share or keep.")
            }

            Section {
                Button(role: .destructive) { showSignOut = true } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                Button(role: .destructive) { showDelete = true } label: {
                    Label("Delete Account", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .sheet(item: $exportFile) { f in ActivityView(items: [f.url]) }
        .alert("Sign out?", isPresented: $showSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                try? Auth.auth().signOut(); dismiss(); onSignOut()
            }
        } message: {
            Text("You'll need to sign back in to use Kulan on this device.")
        }
        .alert("Delete account?", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { working = true; try? await profile.deleteAccount(); working = false; dismiss(); onSignOut() }
            }
        } message: {
            Text("This permanently deletes your account and profile. This can't be undone.")
        }
    }

    // Gather profile + all chats (decrypted) into a text file, then present the share sheet.
    private func exportData() async {
        exporting = true
        let me = AuthService.shared.uid ?? ""
        var out = "Kulan — Data Export\n\n"
        out += "Name: \(profile.me?.name ?? "")\n"
        out += "Username: @\(profile.me?.handle ?? "")\n"
        if let about = profile.me?.about, !about.isEmpty { out += "Bio: \(about)\n" }
        out += "Account ID: \(me)\n\n"

        let convs = await MainActor.run {
            ConversationsRepository.shared.conversations.filter { !$0.isCleared(me) }
        }
        let db = Firestore.firestore()
        for c in convs {
            _ = await Crypto.shared.preloadKey(c.otherUid(me))
            out += "===== Chat with \(c.name(for: me)) =====\n"
            if let snap = try? await db.collection("conversations").document(c.id)
                .collection("messages").order(by: "createdAt").getDocuments() {
                for d in snap.documents {
                    let m = Message(id: d.documentID, data: d.data(), cid: c.id, crypto: Crypto.shared)
                    let who = m.authorId == me ? "You" : c.name(for: me)
                    let when = m.createdAt.formatted(date: .abbreviated, time: .shortened)
                    let body = m.isImage ? "[Photo]" : (m.isAudio ? "[Voice message]"
                              : (m.isCall ? "[Call]" : m.text))
                    out += "[\(when)] \(who): \(body)\n"
                }
            }
            out += "\n"
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Kulan-Data-Export.txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        await MainActor.run { exportFile = ExportFile(url: url); exporting = false }
    }
}

// Wraps a file URL so it can drive a .sheet(item:).
struct ExportFile: Identifiable { let id = UUID(); let url: URL }

// Native share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct AppearanceSettingsView: View {
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    var body: some View {
        List {
            Section {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Choose how Kulan looks. System follows your device setting.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
    }
}

struct PrivacySettingsView: View {
    private var repo = ConversationsRepository.shared
    private var me: String { AuthService.shared.uid ?? "" }
    private var blockedCount: Int { repo.conversations.filter { $0.blockedBy[me] == true }.count }
    @AppStorage("appLockEnabled") private var appLock = false
    @AppStorage("appLockDelay") private var lockDelay = 0   // grace period (seconds) before re-locking
    @AppStorage("screenSecurity") private var screenSecurity = false
    @AppStorage("readReceipts") private var readReceipts = true
    @AppStorage("typingIndicators") private var typingIndicators = true
    @AppStorage("shareLastSeen") private var shareLastSeen = true

    var body: some View {
        List {
            Section {
                Toggle(isOn: $readReceipts) { Label("Read Receipts", systemImage: "checkmark.circle") }.tint(.green)
                Toggle(isOn: $typingIndicators) { Label("Typing Indicators", systemImage: "ellipsis.bubble") }.tint(.green)
                Toggle(isOn: $shareLastSeen) { Label("Last Seen & Online", systemImage: "clock") }.tint(.green)
            } footer: {
                Text("These are reciprocal — if you turn one off, you won't see it from others either.")
            }

            Section {
                NavigationLink { BlockedUsersView() } label: {
                    HStack {
                        Label("Blocked Users", systemImage: "hand.raised")
                        Spacer()
                        Text("\(blockedCount)").foregroundStyle(.secondary)
                    }
                }
                NavigationLink { PhoneNumberPrivacyView() } label: {
                    Label("Phone Number", systemImage: "phone")
                }
            }

            Section {
                Toggle(isOn: $appLock) { Label("App Lock", systemImage: "faceid") }.tint(.green)
                if appLock {
                    Picker(selection: $lockDelay) {
                        Text("Immediately").tag(0)
                        Text("After 1 minute").tag(60)
                        Text("After 5 minutes").tag(300)
                        Text("After 1 hour").tag(3600)
                    } label: { Label("Auto-Lock", systemImage: "clock.arrow.circlepath") }
                }
                Toggle(isOn: $screenSecurity) { Label("Screen Security", systemImage: "eye.slash") }.tint(.green)
            } footer: {
                Text("App Lock requires Face ID / passcode to open Kulan. Auto-Lock sets how long Kulan can be in the background before it locks again. Screen Security hides the app preview in the multitasking switcher.")
            }

            Section {
                Label("End-to-end encrypted", systemImage: "lock.fill")
            } footer: {
                Text("Every message is end-to-end encrypted. The private key lives only on your device — the server can never read your messages.")
            }
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    @State private var storageText = "Calculating…"
    @State private var clearing = false
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: appVersion)
                Label("End-to-end encrypted", systemImage: "lock.fill")
            } footer: {
                Text("Kulan — a Somali messenger. Made for Somalia.")
            }
            Section {
                LabeledContent("Cached media", value: storageText)
                Button {
                    clearing = true
                    Task { await clearCache(); storageText = await computeStorage(); clearing = false }
                } label: {
                    HStack { Label("Clear Cache", systemImage: "trash"); Spacer(); if clearing { ProgressView() } }
                }
                .disabled(clearing)
            } footer: {
                Text("Frees photos and voice notes downloaded to this device. Your messages are never deleted.")
            }
            Section {
                Link(destination: URL(string: "https://kulan-2ef85.web.app/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://kulan-2ef85.web.app/terms.html")!) {
                    Label("Terms & Conditions", systemImage: "doc.text")
                }
                Link(destination: URL(string: "mailto:kulanchat@gmail.com")!) {
                    Label("Report a Problem", systemImage: "envelope")
                }
            } footer: {
                Text("Kulan has zero tolerance for objectionable content or abusive behavior. Reports are reviewed within 24 hours.")
            }
        }
        .navigationTitle("Help & About")
        .navigationBarTitleDisplayMode(.inline)
        .task { storageText = await computeStorage() }
    }

    // Measure downloaded media (temp files + URL cache) off the main thread.
    private func computeStorage() async -> String {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var total = Int64(URLCache.shared.currentDiskUsage)
            total += Int64(DiskImageCache.shared.diskBytes())   // persistent media cache
            if let en = fm.enumerator(at: fm.temporaryDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in en {
                    total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            let f = ByteCountFormatter(); f.allowedUnits = [.useMB, .useKB]; f.countStyle = .file
            return f.string(fromByteCount: total)
        }.value
    }

    // Remove cached/downloaded media only — never touches messages or keys.
    private func clearCache() async {
        DiskImageCache.shared.clear()   // persistent image/story disk cache (memory + disk)
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
                for url in items { try? fm.removeItem(at: url) }
            }
            URLCache.shared.removeAllCachedResponses()
        }.value
    }
}

// MARK: - Story Settings

struct StorySettingsView: View {
    @AppStorage("storyViewReceipts") private var viewReceipts = true

    var body: some View {
        List {
            Section {
                Toggle("Share View Receipts", isOn: $viewReceipts)
            } footer: {
                Text("If on, people see when you've viewed their status, and you can see who viewed yours. If off, neither is shared.")
            }
            Section {
                LabeledContent("Who can see my status", value: "Your chats")
            } footer: {
                Text("Your status is visible for 24 hours to everyone you've chatted with, then it's deleted automatically.")
            }
        }
        .navigationTitle("Stories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Edit Profile

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var handle = ""
    @State private var about = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadTask: Task<Void, Never>?
    @State private var uploading = false
    @State private var saving = false
    @State private var error: String?
    @State private var showUsername = false

    private var cardBG: Color { Color(.secondarySystemGroupedBackground) }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(spacing: 22) {
                        avatarBlock

                        // Name card (first + last → stored as one name).
                        VStack(spacing: 0) {
                            nameField("First name", text: $firstName)
                            Divider().padding(.leading, 18)
                            nameField("Last Name", text: $lastName)
                        }
                        .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // Username row → pushes the dedicated username editor.
                        Button { showUsername = true } label: {
                            HStack {
                                Text("Username").foregroundStyle(.primary)
                                Spacer()
                                Text(handle.isEmpty ? "Set" : "@\(handle)").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 16)
                            .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        // Bio card.
                        TextField("A few words about you", text: $about, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(.horizontal, 18).padding(.vertical, 16)
                            .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .onChange(of: about) { _, v in if v.count > 140 { about = String(v.prefix(140)) } }

                        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                }
            }
        }
        .onAppear {
            let parts = (profile.me?.name ?? "").split(separator: " ", maxSplits: 1).map(String.init)
            firstName = parts.first ?? ""
            lastName = parts.count > 1 ? parts[1] : ""
            handle = profile.me?.handle ?? ""
            about = profile.me?.about ?? ""
        }
        .onChange(of: photoItem) { _, item in
            uploadTask?.cancel()
            uploadTask = Task { await upload(item) }
        }
        .sheet(isPresented: $showUsername) { UsernameEditView(handle: $handle) }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true)
            }
            Spacer()
            Text("Edit Profile").font(.headline)
            Spacer()
            Button { Task { await save() } } label: {
                Text("Save").font(.headline).foregroundStyle(saving ? .secondary : .primary)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .liquidGlass(Capsule(), interactive: true)
            }
            .disabled(saving)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var avatarBlock: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                AvatarView(name: firstName, photoUrl: profile.me?.photoUrl, size: 130)
                    .overlay { if uploading { ZStack { Circle().fill(.black.opacity(0.3)); ProgressView().tint(.white) } } }
            }
            .buttonStyle(.plain)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Text("Change").font(.subheadline.weight(.medium)).foregroundStyle(.blue)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private func nameField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .onChange(of: text.wrappedValue) { _, v in if v.count > 40 { text.wrappedValue = String(v.prefix(40)) } }
    }

    private func upload(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        uploading = true; error = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { uploading = false; return }
            if Task.isCancelled { uploading = false; return }   // a newer pick superseded this one
            try await profile.uploadPhoto(data)
        } catch {
            self.error = "Photo upload failed: \(error.localizedDescription)"
        }
        uploading = false
    }

    private func save() async {
        let n = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        let h = ChatService.sanitizeHandle(handle)
        guard !n.isEmpty else { error = "Enter your name"; return }
        guard ChatService.isValidHandle(h) else {
            error = "Username: letters, numbers and _ only, 3–24 characters"; return
        }
        saving = true; error = nil
        do {
            if let existing = await ChatService.findByHandle(h), existing.id != AuthService.shared.uid {
                error = "That username is taken"; saving = false; return
            }
            try await profile.updateProfile(name: n, handle: h, about: about)
            dismiss()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        saving = false
    }
}

// Dedicated username editor (matches the reference: X · "Username" · blue check, one @field + helper).
struct UsernameEditView: View {
    @Binding var handle: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var cardBG: Color { Color(.secondarySystemGroupedBackground) }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                            .frame(width: 40, height: 40).liquidGlass(Circle(), interactive: true)
                    }
                    Spacer()
                    Text("Username").font(.headline)
                    Spacer()
                    Button {
                        handle = ChatService.sanitizeHandle(draft); dismiss()
                    } label: {
                        Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.blue, in: Circle())
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 1) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("username", text: $draft)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                            .onChange(of: draft) { _, v in let c = ChatService.sanitizeHandle(v); if c != v { draft = c } }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Letters, numbers and _ only. 3–24 characters.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                .padding(16)
                Spacer()
            }
        }
        .onAppear { draft = handle; focused = true }
    }
}
