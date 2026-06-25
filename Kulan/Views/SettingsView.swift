import SwiftUI
import PhotosUI
import FirebaseAuth

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

    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Name", value: profile.me?.name ?? "—")
                LabeledContent("Username", value: profile.me.map { "@\($0.handle)" } ?? "—")
                LabeledContent("Account ID", value: String((AuthService.shared.uid ?? "").prefix(10)) + "…")
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
                Toggle(isOn: $screenSecurity) { Label("Screen Security", systemImage: "eye.slash") }.tint(.green)
            } footer: {
                Text("App Lock requires Face ID / passcode to open Kulan. Screen Security hides the app preview in the multitasking switcher.")
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
    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: appVersion)
                Label("End-to-end encrypted", systemImage: "lock.fill")
            } footer: {
                Text("Kulan — a Somali messenger. Made for Somalia.")
            }
        }
        .navigationTitle("Help & About")
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var name = ""
    @State private var handle = ""
    @State private var about = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                AvatarView(name: name, photoUrl: profile.me?.photoUrl, size: 96)
                                if uploading {
                                    ProgressView().padding(8).background(.thinMaterial, in: Circle())
                                } else {
                                    Image(systemName: "camera.fill")
                                        .font(.caption).padding(7)
                                        .background(.thinMaterial, in: Circle())
                                }
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Your name", text: $name).textInputAutocapitalization(.words)
                        .onChange(of: name) { _, v in if v.count > 40 { name = String(v.prefix(40)) } }
                }
                Section {
                    // "@" prefix so the username field is clearly distinct from the name.
                    HStack(spacing: 1) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("username", text: $handle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: handle) { _, v in
                                let clean = ChatService.sanitizeHandle(v)
                                if clean != v { handle = clean }   // block spaces/symbols as you type
                            }
                    }
                } header: {
                    Text("Username")
                } footer: {
                    Text("Letters, numbers and _ only. 3–24 characters.")
                }
                Section("Bio") {
                    TextField("A few words about you", text: $about, axis: .vertical)
                        .onChange(of: about) { _, v in if v.count > 140 { about = String(v.prefix(140)) } }
                        .lineLimit(1...4)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }.disabled(saving).fontWeight(.semibold)
                }
            }
            .onAppear {
                name = profile.me?.name ?? ""
                handle = profile.me?.handle ?? ""
                about = profile.me?.about ?? ""
            }
            .onChange(of: photoItem) { _, item in Task { await upload(item) } }
        }
    }

    private func upload(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        uploading = true; error = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { uploading = false; return }
            try await profile.uploadPhoto(data)
        } catch {
            self.error = "Photo upload failed: \(error.localizedDescription)"
        }
        uploading = false
    }

    private func save() async {
        let n = name.trimmingCharacters(in: .whitespaces)
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
