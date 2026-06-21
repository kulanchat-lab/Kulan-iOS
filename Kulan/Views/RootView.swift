import SwiftUI

struct RootView: View {
    enum Phase { case loading, onboarding, main }
    @State private var phase: Phase = .loading
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.bg(scheme == .dark).ignoresSafeArea()
            switch phase {
            case .loading:
                ProgressView()
            case .onboarding:
                OnboardingView { phase = .main }
            case .main:
                MainShell(onSignOut: { Task { await route() } })
            }
        }
        .task { await route() }
    }

    private func route() async {
        phase = .loading
        await AuthService.shared.bootstrap()
        try? await Crypto.shared.ensureReady()
        await ProfileStore.shared.loadMine()
        phase = (ProfileStore.shared.me?.handle.isEmpty == false) ? .main : .onboarding
    }
}

struct OnboardingView: View {
    var onDone: () -> Void
    @State private var name = ""
    @State private var handle = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Username", text: $handle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Create your profile")
                } footer: {
                    Text("Pick a name and a username so friends can find you.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Welcome to Kulan")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Continue").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .disabled(saving)
            }
        }
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
            try await ProfileStore.shared.updateProfile(name: n, handle: h)
            onDone()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        saving = false
    }
}
