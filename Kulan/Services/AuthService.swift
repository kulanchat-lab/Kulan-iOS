import Foundation
import Observation
import FirebaseAuth

/// Anonymous auth (matches the RN app). `uid` drives every repository.
@Observable
final class AuthService {
    static let shared = AuthService()
    private init() {}

    var uid: String?

    func bootstrap() async {
        if let user = Auth.auth().currentUser {
            uid = user.uid
            return
        }
        do {
            let result = try await Auth.auth().signInAnonymously()
            uid = result.user.uid
        } catch {
            print("auth: anonymous sign-in failed:", error)
        }
    }
}
