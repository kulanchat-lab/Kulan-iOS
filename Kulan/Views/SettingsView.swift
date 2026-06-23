import SwiftUI
import PhotosUI
import FirebaseAuth

// Parent settings — profile cell on top, then grouped rows that push to dedicated
// sub-screens (the Signal/Telegram structure), built our way with native List.
struct SettingsView: View {
    var onSignOut: () -> Void
    init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

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
                    Button { showEdit = true } label: { profileCell }
                }

                Section {
                    NavigationLink { AccountSettingsView(onSignOut: onSignOut) } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                    NavigationLink { DevicesView() } label: {
                        Label("Devices", systemImage: "laptopcomputer.and.iphone")
                    }
                }

                Section {
                    NavigationLink { NotificationsSettingsView() } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    NavigationLink { AppearanceSettingsView() } label: {
                        Label("Appearance", systemImage: "paintbrush")
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
            .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showEdit) { EditProfileView() }
            .sheet(isPresented: $showQR) { MyQRView() }
        }
    }

    private var profileCell: some View {
        HStack(spacing: 14) {
            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.me?.name ?? "You").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                if let h = profile.me?.handle, !h.isEmpty {
                    Text("@\(h)").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Edit profile").font(.footnote).foregroundStyle(.tint)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
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

    var body: some View {
        List {
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
                }
                Section("Username") {
                    TextField("username", text: $handle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Bio") {
                    TextField("A few words about you", text: $about, axis: .vertical)
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
        let h = handle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !n.isEmpty else { error = "Enter your name"; return }
        guard h.count >= 3 else { error = "Username must be at least 3 characters"; return }
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
