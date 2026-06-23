import Foundation
import CallKit
import AVFoundation
import WebRTC

// Bridges our WebRTC calls to the native iOS call UI (CallKit): the green status
// pill, the system call screen with Speaker/Mic/Hang-up, and (with VoIP push)
// lock-screen ringing. Handles the audio-session hand-off WebRTC needs under CallKit.
//
// NOTE: untested from CI — CallKit + live audio need two real devices.
final class CallKitManager: NSObject {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    private(set) var activeUUID: UUID?

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // WebRTC must not touch the audio session itself under CallKit.
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    // MARK: - Outgoing
    func startOutgoing(name: String) -> UUID {
        let uuid = UUID()
        activeUUID = uuid
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: name))
        controller.request(CXTransaction(action: action)) { _ in }
        return uuid
    }
    func reportConnecting() { if let u = activeUUID { provider.reportOutgoingCall(with: u, startedConnectingAt: nil) } }
    func reportConnected() { if let u = activeUUID { provider.reportOutgoingCall(with: u, connectedAt: nil) } }

    // MARK: - Incoming
    func reportIncoming(name: String, completion: (() -> Void)? = nil) {
        let uuid = UUID()
        activeUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in completion?() }
    }

    // MARK: - End
    func end() {
        guard let uuid = activeUUID else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
        activeUUID = nil
    }
    /// Remote hung up / call failed — clear the system UI without a user action.
    func reportEnded() {
        if let uuid = activeUUID { provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded) }
        activeUUID = nil
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) { CallService.shared.hangUp() }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        configureAudio()
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        configureAudio()
        CallService.shared.answer()
        action.fulfill()
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        CallService.shared.hangUp()
        activeUUID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    private func configureAudio() {
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        try? s.setMode(.voiceChat)
        s.unlockForConfiguration()
    }
}
