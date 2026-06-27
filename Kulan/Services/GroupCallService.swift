import Foundation
import LiveKit

// Group calls run on LiveKit (an SFU) — phones can't mesh more than ~3 people. The 1:1 calls
// stay on stasel/WebRTC; LiveKit ships LK-prefixed WebRTC so the two coexist.
// This is a minimal link-check stub; the full service (connect/publish/grid) is built next.
@MainActor
final class GroupCallService {
    static let shared = GroupCallService()
    private init() {}

    let room = Room()
    var isConnected: Bool { room.connectionState == .connected }
}
