import Foundation
import LiveKit
import FirebaseFunctions

// Group calls run on LiveKit (an SFU) — phones can't mesh more than ~3 people. 1:1 calls stay on
// stasel/WebRTC; LiveKit ships LK-prefixed WebRTC so the two coexist. The join token is minted
// server-side by the `groupCallToken` function (our API secret never touches the app).
@MainActor
final class GroupCallService: ObservableObject {
    static let shared = GroupCallService()
    private init() {}

    // Public LiveKit server address (not a secret — it's just where the app connects).
    private let url = "wss://kulan-irgnsxba.livekit.cloud"

    let room = Room()                       // observe this in the UI for live participant updates
    @Published var activeCid: String?       // nil = no group call in progress
    @Published var isVideo = false
    @Published var micOn = true
    @Published var cameraOn = false
    @Published var connecting = false
    @Published var callTitle = ""

    var isActive: Bool { activeCid != nil }

    func start(cid: String, title: String, video: Bool) async {
        guard activeCid == nil else { return }
        connecting = true; isVideo = video; callTitle = title
        do {
            let res = try await Functions.functions(region: "me-central1")
                .httpsCallable("groupCallToken").call(["cid": cid])
            guard let d = res.data as? [String: Any], let token = d["token"] as? String else {
                connecting = false; return
            }
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(enabled: true)
            if video { try await room.localParticipant.setCamera(enabled: true) }
            activeCid = cid; micOn = true; cameraOn = video; connecting = false
        } catch {
            connecting = false
            await disconnect()
        }
    }

    func toggleMic() {
        micOn.toggle(); let v = micOn
        Task { try? await room.localParticipant.setMicrophone(enabled: v) }
    }
    func toggleCamera() {
        cameraOn.toggle(); let v = cameraOn
        Task { try? await room.localParticipant.setCamera(enabled: v) }
    }

    func end() { Task { await disconnect() } }

    private func disconnect() async {
        await room.disconnect()
        activeCid = nil; micOn = true; cameraOn = false; isVideo = false; callTitle = ""
    }
}
