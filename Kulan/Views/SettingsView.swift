import SwiftUI
import PhotosUI
import FirebaseAuth

struct SettingsView: View {
    var onSignOut: () -> Void
    init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @State private var showEdit = false
    @State private var showDelete = false
    @State private var working = false

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    private var inviteText: String {
        let h = profile.me?.handle ?? ""
        return h.isEmpty ? "Chat with me on Kulan." : "Chat with me on Kulan — my username is @\(h)"
    }

    var body: some View {
        NavigationStack {
            List {
                // Profile card — native inset-grouped row (Apple Settings look).
                Section {
                    Button { showEdit = true } label: {
                        HStack(spacing: 14) {
                            AvatarView(name: profile.me?.name ?? "", photoUrl: profile.me?.photoUrl, size: 60)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.me?.name ?? "You")
                                    .font(.title3.weight(.semibold)).foregroundStyle(.primary)
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

                // Appearance — Light / Dark / System (applies app-wide instantly).
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                // Account details.
                Section("Account") {
                    LabeledContent("Name", value: profile.me?.name ?? "—")
                    LabeledContent("Username", value: profile.me.map { "@\($0.handle)" } ?? "—")
                    LabeledContent("Account ID", value: String((AuthService.shared.uid ?? "").prefix(10)) + "…")
                }

                Section {
                    ShareLink(item: inviteText) {
                        Label("Invite Friends", systemImage: "person.badge.plus")
                    }
                }

                Section {
                    Label { Text("End-to-end encrypted") } icon: { Image(systemName: "lock.fill") }
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("Kulan — a Somali messenger. Messages are end-to-end encrypted.")
                }

                Section {
                    Button(role: .destructive) {
                        try? Auth.auth().signOut()
                        dismiss()
                        onSignOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    Button(role: .destructive) {
                        showDelete = true
                    } label: {
                        Label("Delete Account", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Flip the open sheet instantly with the appearance picker (sheets keep
            // their own environment, so apply the scheme here too).
            .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .disabled(working)
            .sheet(isPresented: $showEdit) { EditProfileView() }
            .alert("Delete account?", isPresented: $showDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        working = true
                        try? await profile.deleteAccount()
                        working = false
                        dismiss()
                        onSignOut()
                    }
                }
            } message: {
                Text("This permanently deletes your account and profile. This can't be undone.")
            }
        }
    }
}

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    private var profile = ProfileStore.shared
    @State private var name = ""
    @State private var handle = ""
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
            try await profile.updateProfile(name: n, handle: h)
            dismiss()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        saving = false
    }
}
