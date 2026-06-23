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
                .onOpenURL { url in handleDeepLink(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await PresenceService.set(online: phase == .active) }
        }
    }

    // kulan://u/<handle> — open (or start) a chat with that user.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "kulan", url.host == "u" else { return }
        let handle = url.pathComponents.last(where: { $0 != "/" }) ?? ""
        guard !handle.isEmpty else { return }
        Task {
            guard let user = await ChatService.findByHandle(handle),
                  let cid = try? await ChatService.openConversation(other: user) else { return }
            await MainActor.run { AppRouter.shared.pendingChatId = cid }
        }
    }
}
