import SwiftUI
import FirebaseCore
import FirebaseFirestore

@main
struct KulanApp: App {
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
        }
    }
}
