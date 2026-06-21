import SwiftUI
import FirebaseCore
import FirebaseFirestore

@main
struct KulanApp: App {
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FirebaseApp.configure()

        // REAL on-disk offline persistence — the thing the JS SDK could not do in
        // Hermes (no IndexedDB). Native gives us airplane-mode + cold-start for free.
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await PresenceService.set(online: phase == .active) }
        }
    }
}
