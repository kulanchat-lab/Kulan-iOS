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
                MainShell()
            }
        }
        .task {
            await AuthService.shared.bootstrap()
            try? await Crypto.shared.ensureReady()
            await ProfileStore.shared.loadMine()
            phase = (ProfileStore.shared.me?.handle.isEmpty == false) ? .main : .onboarding
        }
    }
}

struct OnboardingView: View {
    var onDone: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var handle = ""
    @State private var saving = false
    @State private var error: String?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Welcome to Kulan").font(.largeTitle.weight(.bold))
            Text("Pick a name and a username so friends can find you.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                TextField("Your name", text: $name)
                    .textInputAutocapitalization(.words)
                    .padding().background(Theme.card(dark)).clipShape(RoundedRectangle(cornerRadius: 14))
                TextField("username", text: $handle)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding().background(Theme.card(dark)).clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if let error { Text(error).foregroundStyle(.red).font(.footnote) }

            Button {
                Task { await save() }
            } label: {
                Group {
                    if saving { ProgressView().tint(Theme.onAccent(dark)) }
                    else { Text("Continue").fontWeight(.semibold) }
                }
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Theme.accent(dark)).foregroundColor(Theme.onAccent(dark))
                .clipShape(RoundedRectangle(cornerRadius: 25))
            }
            .disabled(saving)
            Spacer()
        }
        .padding(24)
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
