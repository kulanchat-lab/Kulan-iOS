import SwiftUI

@main
struct KulanApp: App {
    // Firebase config + APNs/FCM handshake live in the app delegate.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.primary)   // monochrome: no iOS system-blue anywhere
                .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? nil)
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await PresenceService.set(online: phase == .active) }
        }
    }
}
