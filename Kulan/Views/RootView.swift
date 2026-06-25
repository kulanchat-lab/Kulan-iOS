import SwiftUI
import LocalAuthentication

struct RootView: View {
    enum Phase { case loading, onboarding, main }
    @State private var phase: Phase = .loading
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLockEnabled") private var lockEnabled = false
    @AppStorage("screenSecurity") private var screenSecurity = false
    @State private var locked = false

    var body: some View {
        ZStack {
            Theme.bg(scheme == .dark).ignoresSafeArea()
            switch phase {
            case .loading:
                // Static branded launch screen (no spinner) — matches the native iOS launch
                // screen so boot feels instant, like other chat apps. No "loading" UI.
                Text("Kulan").font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            case .onboarding:
                OnboardingView { phase = .main }
            case .main:
                // Root-level call container so an active call (full screen or top mini
                // bar) lives above every screen and survives all navigation.
                CallContainer {
                    MainShell(onSignOut: { Task { await route() } })
                }
            }

            // Screen security: blank the app preview in the app switcher.
            if screenSecurity && scenePhase != .active && !locked {
                Theme.bg(scheme == .dark).ignoresSafeArea()
                    .overlay(Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary))
            }
            // App Lock overlay.
            if locked { LockScreen { authenticate() } }
        }
        .task { await route() }
        .onAppear { if lockEnabled { locked = true; authenticate() } }
        .onChange(of: scenePhase) { _, new in
            if new == .background, lockEnabled { locked = true }   // lock when leaving
            if new == .active, locked { authenticate() }           // prompt on return
        }
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            locked = false; return   // no passcode/biometrics set up — don't lock the user out
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Kulan") { ok, _ in
            DispatchQueue.main.async { if ok { locked = false } }
        }
    }

    private func route() async {
        phase = .loading
        await AuthService.shared.bootstrap()
        try? await Crypto.shared.ensureReady()
        await ProfileStore.shared.loadMine()
        // Re-publish the public key now that the profile doc exists — self-heals
        // accounts that failed to publish on a first launch (otherwise others can
        // never message them: "hasn't set up encryption yet").
        await Crypto.shared.publishPublicKey()
        let ready = ProfileStore.shared.me?.handle.isEmpty == false
        if ready { Push.register(); Push.saveVoipToken() }   // notifications + VoIP token now that we're signed in
        phase = ready ? .main : .onboarding
    }
}

// Full-screen lock shown when App Lock is on.
struct LockScreen: View {
    var onUnlock: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Theme.bg(scheme == .dark).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Kulan is locked").font(.headline)
                Button { onUnlock() } label: {
                    Label("Unlock", systemImage: "faceid").font(.body.weight(.semibold))
                        .padding(.horizontal, 24).frame(height: 48)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                }
            }
        }
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
                    HStack(spacing: 1) {
                        Text("@").foregroundStyle(.secondary)
                        TextField("Username", text: $handle)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: handle) { _, v in
                                let clean = ChatService.sanitizeHandle(v)
                                if clean != v { handle = clean }
                            }
                    }
                } header: {
                    Text("Create your profile")
                } footer: {
                    Text("Username: letters, numbers and _ only, 3–24 characters.")
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
            try await ProfileStore.shared.updateProfile(name: n, handle: h)
            await Crypto.shared.publishPublicKey()   // doc now exists — ensure key is live
            onDone()
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        saving = false
    }
}
