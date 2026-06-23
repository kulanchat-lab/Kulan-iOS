import UIKit
import SwiftUI
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth
import FirebaseMessaging
import UserNotifications

// App delegate: configures Firebase, owns the APNs/FCM token handshake, and saves
// the device's FCM token to users/{uid}.fcmTokens so the Cloud Function can push
// to it. (Firebase config lives here so it runs before any messaging setup.)
final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FirebaseApp.configure()

        // REAL on-disk offline persistence (the win the JS SDK couldn't do in Hermes).
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings

        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("push: APNs registration failed:", error)
    }

    // FCM rotation token → save it so the Cloud Function can target this device.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid)
            .setData(["fcmTokens": FieldValue.arrayUnion([token])], merge: true)
    }

    // Foreground banner — but NOT for the chat you're already looking at.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let cid = notification.request.content.userInfo["cid"] as? String
        if let cid, cid == AppRouter.shared.activeChatId { return [] }
        return [.banner, .sound, .badge]
    }

    // Tapping a push opens the right chat (works from background AND cold launch —
    // MainShell consumes the pending route once the conversation list is loaded).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let cid = response.notification.request.content.userInfo["cid"] as? String {
            await MainActor.run { AppRouter.shared.pendingChatId = cid }
        }
    }
}

// App-wide navigation intents (deep links) + which chat is on screen.
@Observable final class AppRouter {
    static let shared = AppRouter()
    private init() {}
    var pendingChatId: String?    // a chat to open from a notification tap
    var activeChatId: String?     // the chat currently on screen (suppresses its own banners)
}

// Clear a chat's delivered notifications + fix the app badge when you read it.
enum NotificationCleaner {
    static func clear(cid: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let ids = notes
                .filter { ($0.request.content.userInfo["cid"] as? String) == cid }
                .map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
        // Badge = total unread across the OTHER chats (this one is now read).
        let me = Auth.auth().currentUser?.uid ?? ""
        let total = ConversationsRepository.shared.conversations
            .filter { $0.id != cid }
            .reduce(0) { $0 + $1.unread(me) }
        center.setBadgeCount(max(0, total))
    }
}

enum Push {
    /// Ask for permission, then register with APNs (FCM token follows via the delegate).
    /// Safe to call on every launch once signed in — iOS only prompts once.
    static func register() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Stop push to this device: drop its FCM token so the Cloud Function skips it.
    static func unregister() {
        guard let uid = Auth.auth().currentUser?.uid, let token = Messaging.messaging().fcmToken else { return }
        Firestore.firestore().collection("users").document(uid)
            .updateData(["fcmTokens": FieldValue.arrayRemove([token])])
    }
}
