import Foundation
import Observation
import AVFoundation
import WebRTC
import FirebaseAuth
import FirebaseFirestore

// Voice calling over WebRTC, signalled through Firestore `calls/{id}` (offer/answer
// + caller/callee ICE candidate subcollections) — the same design the RN web client
// used. Media is peer-to-peer (STUN/TURN); the server only relays signalling.
//
// NOTE: untested from CI — WebRTC needs two real devices. Compile-checked only.
@Observable
final class CallService: NSObject {
    static let shared = CallService()

    // .reconnecting = the media path dropped mid-call; we're trying to recover it.
    enum State: Equatable { case idle, outgoing, incoming, active, reconnecting, ended }

    // Why a call ended — drives the end tone, the status label, and the call record.
    enum EndReason: String { case none, hangup, declined, missed, failed, busy }

    var state: State = .idle {
        didSet {
            if state == .active && connectedDate == nil { connectedDate = Date() }
            if state == .idle {
                connectedDate = nil; isMuted = false; isSpeaker = false
                calleeRinging = false; recordWritten = false; minimized = false
                endReason = .none; negotiationVersion = 0; appliedRemoteRestart = 0
                stopRingback(); stopTone(); cancelTimers()
            }
        }
    }
    var otherName: String = ""
    var otherPhotoUrl: String?
    var isMuted = false
    var isSpeaker = false
    var minimized = false            // call screen minimized -> show the floating pill instead
    var calleeRinging = false        // caller: the other phone is actually ringing now
    var connectedDate: Date?
    var endReason: EndReason = .none // last/in-progress end reason (UI reads it for the label)
    private var recordWritten = false
    private var ringbackPlayer: AVAudioPlayer?
    private var tonePlayer: AVAudioPlayer?       // busy / ended one-shot tones
    private var localAudioTrack: RTCAudioTrack?
    private(set) var callId: String?
    private var otherUid: String = ""
    private var isCaller = false

    // Reconnection / lifecycle timers.
    private var noAnswerWork: DispatchWorkItem?      // outgoing: nobody answered -> Missed
    private var iceRestartWork: DispatchWorkItem?    // delayed ICE restart after a drop
    private var reconnectGiveUpWork: DispatchWorkItem? // hard cap: can't recover -> Failed
    private var negotiationVersion = 0               // bumps each ICE restart (caller)
    private var appliedRemoteRestart = 0             // last restart version we applied

    private let db = Firestore.firestore()
    private var pc: RTCPeerConnection?
    private var listeners: [ListenerRegistration] = []
    private var incomingListener: ListenerRegistration?

    private var me: String { Auth.auth().currentUser?.uid ?? "" }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let config: RTCConfiguration = {
        let c = RTCConfiguration()
        c.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302",
                                      "stun:stun1.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["turn:openrelay.metered.ca:80"],
                         username: "openrelayproject", credential: "openrelayproject"),
        ]
        c.sdpSemantics = .unifiedPlan
        return c
    }()

    // Audio session is owned by CallKit (manual mode) — see CallKitManager.

    private func makePeerConnection() -> RTCPeerConnection? {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        // Local mic track.
        let audioSource = Self.factory.audioSource(with: nil)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        connection?.add(audioTrack, streamIds: ["stream0"])
        localAudioTrack = audioTrack
        return connection
    }

    // MARK: - In-call controls
    func toggleMute() {
        isMuted.toggle()
        localAudioTrack?.isEnabled = !isMuted
    }
    func toggleSpeaker() {
        isSpeaker.toggle()
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        try? rtc.overrideOutputAudioPort(isSpeaker ? .speaker : .none)
        rtc.unlockForConfiguration()
    }

    // Ringback the CALLER hears while waiting (generated tone, looped). Ensure the
    // audio unit is on + allow mixing so the player outputs while CallKit owns the session.
    private func startRingback() {
        guard ringbackPlayer == nil else { return }
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers])
        s.isAudioEnabled = true
        s.unlockForConfiguration()
        ringbackPlayer = try? AVAudioPlayer(data: RingbackTone.wavData())
        ringbackPlayer?.numberOfLoops = -1
        ringbackPlayer?.prepareToPlay()
        ringbackPlayer?.play()
    }
    private func stopRingback() { ringbackPlayer?.stop(); ringbackPlayer = nil }

    // One-shot call-progress tone (busy/declined or ended). Same audio-session nudge
    // as ringback so it outputs while CallKit owns the session.
    private func playTone(_ data: Data, loops: Int) {
        stopTone()
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers])
        s.isAudioEnabled = true
        s.unlockForConfiguration()
        tonePlayer = try? AVAudioPlayer(data: data)
        tonePlayer?.numberOfLoops = loops
        tonePlayer?.prepareToPlay()
        tonePlayer?.play()
    }
    private func stopTone() { tonePlayer?.stop(); tonePlayer = nil }

    // Play the right tone for how a call ended (caller/receiver feedback).
    private func playEndTone(_ reason: EndReason) {
        stopRingback()
        switch reason {
        case .declined, .busy: playTone(RingbackTone.busyData(), loops: 3)   // ~4s busy signal
        case .failed, .hangup, .missed: playTone(RingbackTone.endedData(), loops: 0)
        case .none: break
        }
    }

    // MARK: - Lifecycle timers

    private func startNoAnswerTimeout() {
        noAnswerWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.state == .outgoing else { return }   // still never connected
            self.endReason = .missed
            self.hangUp()
        }
        noAnswerWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: w)   // ~45s, like big apps
    }

    private func cancelTimers() {
        noAnswerWork?.cancel(); noAnswerWork = nil
        iceRestartWork?.cancel(); iceRestartWork = nil
        reconnectGiveUpWork?.cancel(); reconnectGiveUpWork = nil
    }

    // MARK: - Reconnection (bad / lost connection)

    // Media path dropped. `disconnected` may self-heal, so we wait a few seconds before
    // forcing an ICE restart; `failed` won't, so we restart now. Either way we show
    // "Reconnecting…" and give up after a hard cap.
    private func enterReconnecting(restartAfter delay: Double) {
        guard state == .active || state == .reconnecting else { return }
        if state == .active { state = .reconnecting }
        // Hard cap: if we still haven't recovered, end as Failed.
        if reconnectGiveUpWork == nil {
            let g = DispatchWorkItem { [weak self] in
                guard let self, self.state == .reconnecting else { return }
                self.endReason = .failed
                self.hangUp()
            }
            reconnectGiveUpWork = g
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: g)
        }
        // The caller drives the ICE restart (avoids glare).
        guard isCaller else { return }
        iceRestartWork?.cancel()
        let r = DispatchWorkItem { [weak self] in
            guard let self, self.state == .reconnecting else { return }
            self.restartIce()
        }
        iceRestartWork = r
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: r)
    }

    private func recovered() {
        iceRestartWork?.cancel(); iceRestartWork = nil
        reconnectGiveUpWork?.cancel(); reconnectGiveUpWork = nil
        if state == .reconnecting { state = .active }
    }

    // Caller-only: renegotiate ICE (new credentials + candidates), media keeps flowing
    // on recovery. Cheaper than a full re-offer — DTLS/SRTP keys are preserved.
    private func restartIce() {
        guard isCaller, let pc = pc, let id = callId else { return }
        negotiationVersion += 1
        let v = negotiationVersion
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["IceRestart": "true"],
                                              optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp, let pc = self.pc else { return }
            pc.setLocalDescription(sdp) { _ in
                self.db.collection("calls").document(id)
                    .updateData(["restartOffer": ["sdp": sdp.sdp, "version": v]])
            }
        }
    }

    // Callee marks the call as "ringing" so the caller can switch Calling… → Ringing….
    private func markRinging() {
        guard let id = callId else { return }
        db.collection("calls").document(id).updateData(["ringingAt": FieldValue.serverTimestamp()])
    }

    // MARK: - Outgoing

    func startCall(to uid: String, name: String, photo: String? = nil) {
        guard state == .idle, !uid.isEmpty else { return }
        isCaller = true
        otherUid = uid
        otherName = name
        otherPhotoUrl = photo
        state = .outgoing
        CallKitManager.shared.startOutgoing(name: name)   // native call UI + audio session
        CallKitManager.shared.reportConnecting()

        ensureMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.hangUp(); return }   // no mic -> don't start a dead call
            self.startRingback()        // caller hears "ring… ring…" right away, like a real phone
            self.startNoAnswerTimeout() // give up after ~45s -> Missed
            let ref = self.db.collection("calls").document()
            self.callId = ref.documentID
            self.pc = self.makePeerConnection()
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            self.pc?.offer(for: constraints) { [weak self] sdp, _ in
                guard let self, let sdp, let pc = self.pc else { return }
                pc.setLocalDescription(sdp) { _ in
                    ref.setData([
                        "caller": self.me,
                        "callee": uid,
                        "callerName": ProfileStore.shared.me?.name ?? "Caller",
                        "callerPhoto": ProfileStore.shared.me?.photoUrl ?? "",
                        "type": "voice",
                        "status": "ringing",
                        "offer": ["sdp": sdp.sdp, "type": "offer"],
                        "createdAt": FieldValue.serverTimestamp(),
                    ])
                }
            }
            self.observeCallDoc(ref)
            self.observeRemoteCandidates(ref.collection("calleeCandidates"))
        }
    }

    private func ensureMicPermission(_ done: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: done(true)
        case .denied:  done(false)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
        @unknown default: done(false)
        }
    }

    // MARK: - Incoming

    /// App-wide listener: ring when someone calls me.
    func observeIncoming() {
        incomingListener?.remove()
        guard !me.isEmpty else { return }
        incomingListener = db.collection("calls")
            .whereField("callee", isEqualTo: me)
            .whereField("status", isEqualTo: "ringing")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self, self.state == .idle,
                      let doc = snap?.documents.first else { return }
                let d = doc.data()
                let caller = d["caller"] as? String ?? ""
                // Silent block: a call from someone I've blocked never rings me.
                let cid = [self.me, caller].sorted().joined(separator: "_")
                self.db.collection("conversations").document(cid).getDocument { cs, _ in
                    let blocked = ((cs?.data()?["blockedBy"] as? [String: Any])?[self.me] as? Bool) ?? false
                    guard !blocked, self.state == .idle else { return }
                    self.callId = doc.documentID
                    self.otherUid = caller
                    self.otherName = d["callerName"] as? String ?? "Caller"
                    let photo = d["callerPhoto"] as? String ?? ""
                    self.otherPhotoUrl = photo.isEmpty ? nil : photo
                    self.isCaller = false
                    self.state = .incoming
                    CallKitManager.shared.reportIncoming(callId: doc.documentID, name: self.otherName)
                    self.markRinging()
                }
            }
    }

    /// Set up an incoming call from a VoIP push (app may be cold-launching) so that a
    /// subsequent CallKit answer connects. No ringing here — CallKit shows the ring.
    func prepareIncoming(callId: String, name: String, uid: String, photo: String?) {
        self.callId = callId
        self.otherName = name
        self.otherUid = uid
        self.otherPhotoUrl = (photo?.isEmpty == false) ? photo : nil
        self.isCaller = false
        self.state = .incoming   // so the UI can present once answered
        markRinging()
    }

    func answer() {
        guard let id = callId else { return }
        state = .active   // present the call screen immediately; SDP fills in below
        ensureMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.hangUp(); return }
            let ref = self.db.collection("calls").document(id)
            self.pc = self.makePeerConnection()
            ref.getDocument(source: .server) { [weak self] snap, _ in
                guard let self else { return }
                guard let d = snap?.data(),
                      let offer = d["offer"] as? [String: String], let sdp = offer["sdp"],
                      let pc = self.pc else { self.hangUp(); return }   // bail cleanly, don't get stuck
                let remote = RTCSessionDescription(type: .offer, sdp: sdp)
                pc.setRemoteDescription(remote) { _ in
                    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                    pc.answer(for: constraints) { answerSdp, _ in
                        guard let answerSdp else { return }
                        pc.setLocalDescription(answerSdp) { _ in
                            ref.updateData([
                                "answer": ["sdp": answerSdp.sdp, "type": "answer"],
                                "status": "active",
                            ])
                        }
                    }
                }
                self.observeCallDoc(ref)
                self.observeRemoteCandidates(ref.collection("callerCandidates"))
            }
        }
    }

    // MARK: - Signalling observers

    private func observeCallDoc(_ ref: DocumentReference) {
        let l = ref.addSnapshotListener { [weak self] snap, _ in
            guard let self, let d = snap?.data() else { return }

            // Remote ended (hang up / decline / unreachable) — play the matching tone,
            // then tear down. Do this first and bail.
            if (d["status"] as? String) == "ended", self.state != .ended, self.state != .idle {
                let reason = EndReason(rawValue: d["endReason"] as? String ?? "") ?? .hangup
                self.remoteEnded(reason: reason)
                return
            }

            // Caller: the callee's device is now ringing → "Calling…" becomes "Ringing…".
            if self.isCaller, d["ringingAt"] != nil, !self.calleeRinging, self.state == .outgoing {
                self.calleeRinging = true
            }
            // Caller applies the answer once it arrives → connected.
            if self.isCaller, let answer = d["answer"] as? [String: String], let sdp = answer["sdp"],
               self.pc?.remoteDescription == nil {
                self.noAnswerWork?.cancel()
                self.stopRingback()
                self.pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in }
                self.state = .active
                CallKitManager.shared.reportConnected()
            }
            // Callee applies an ICE-restart OFFER (reconnection) and answers it.
            if !self.isCaller, let ro = d["restartOffer"] as? [String: Any],
               let sdp = ro["sdp"] as? String,
               let v = (ro["version"] as? NSNumber)?.intValue, v > self.appliedRemoteRestart,
               let pc = self.pc {
                self.appliedRemoteRestart = v
                pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { _ in
                    let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                    pc.answer(for: c) { ans, _ in
                        guard let ans else { return }
                        pc.setLocalDescription(ans) { _ in
                            ref.updateData(["restartAnswer": ["sdp": ans.sdp, "version": v]])
                        }
                    }
                }
            }
            // Caller applies the ICE-restart ANSWER.
            if self.isCaller, let ra = d["restartAnswer"] as? [String: Any],
               let sdp = ra["sdp"] as? String,
               let v = (ra["version"] as? NSNumber)?.intValue,
               v == self.negotiationVersion, v > self.appliedRemoteRestart, let pc = self.pc {
                self.appliedRemoteRestart = v
                pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in }
            }
        }
        listeners.append(l)
    }

    private func observeRemoteCandidates(_ col: CollectionReference) {
        let l = col.addSnapshotListener { [weak self] snap, _ in
            guard let self else { return }
            snap?.documentChanges.forEach { change in
                guard change.type == .added else { return }
                let c = change.document.data()
                guard let sdp = c["candidate"] as? String else { return }
                let candidate = RTCIceCandidate(
                    sdp: sdp,
                    sdpMLineIndex: Int32((c["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                    sdpMid: c["sdpMid"] as? String
                )
                self.pc?.add(candidate) { _ in }
            }
        }
        listeners.append(l)
    }

    private var myCandidatesCollection: CollectionReference? {
        guard let id = callId else { return nil }
        return db.collection("calls").document(id)
            .collection(isCaller ? "callerCandidates" : "calleeCandidates")
    }

    // MARK: - Hang up / cleanup

    // System-/remote-initiated end (timeout, ICE failure, remote hang up) — plays a
    // feedback tone for this user and clears the system UI.
    func hangUp() { finishCall(updateRemote: true, clearCallKit: true, localUser: false) }
    // The local user pressed End via CallKit — no tone (they know), don't re-report.
    func endFromCallKit() { finishCall(updateRemote: true, clearCallKit: false, localUser: true) }
    // The other side ended the call — carry their reason so we play the right tone.
    private func remoteEnded(reason: EndReason) {
        endReason = reason
        finishCall(updateRemote: false, clearCallKit: true, localUser: false)
    }

    private func finishCall(updateRemote: Bool, clearCallKit: Bool, localUser: Bool) {
        cancelTimers()
        stopRingback()
        if endReason == .none {   // infer it: connected→hang up, else caller=missed / callee=declined
            endReason = connectedDate != nil ? .hangup : (isCaller ? .missed : .declined)
        }
        // Write a call record into the chat (once). Each side writes its own row.
        if !recordWritten, !otherUid.isEmpty {
            recordWritten = true
            let connected = connectedDate != nil
            let dur = connected ? Int(Date().timeIntervalSince(connectedDate!)) : 0
            let callerUidVal = isCaller ? me : otherUid
            let outcome = connected ? "answered" : "missed"
            let cid = [me, otherUid].sorted().joined(separator: "_")
            let cidCallId = callId ?? UUID().uuidString
            Task { await ChatService.recordCall(cid: cid, callId: cidCallId, callerUid: callerUidVal, outcome: outcome, durationSec: dur) }
        }
        if updateRemote, let id = callId {
            db.collection("calls").document(id).updateData(["status": "ended", "endReason": endReason.rawValue])
        }
        listeners.forEach { $0.remove() }
        listeners = []
        pc?.close()
        pc = nil
        callId = nil
        otherUid = ""
        isCaller = false

        // Feedback tone for the non-initiating side / system-ended calls. Keep the audio
        // session alive until the tone finishes, THEN clear CallKit (which deactivates it).
        let reason = endReason
        if !localUser, reason != .none {
            playEndTone(reason)
            let toneDur = (reason == .declined || reason == .busy) ? 1.8 : 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + toneDur) {
                self.stopTone()
                if clearCallKit { CallKitManager.shared.reportEnded() }
            }
        } else if clearCallKit {
            CallKitManager.shared.reportEnded()
        }

        state = .ended
        // Keep the final state visible briefly (longer for the busy tone) before idle.
        let idleDelay = (!localUser && (reason == .declined || reason == .busy)) ? 2.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay) {
            if self.state == .ended { self.state = .idle }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension CallService: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        myCandidatesCollection?.addDocument(data: [
            "candidate": candidate.sdp,
            "sdpMLineIndex": candidate.sdpMLineIndex,
            "sdpMid": candidate.sdpMid as Any,
        ])
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                self.recovered()                          // back to a healthy media path
            case .disconnected:
                self.enterReconnecting(restartAfter: 3)   // may self-heal; force a restart in 3s
            case .failed:
                self.enterReconnecting(restartAfter: 0)   // won't self-heal; restart now
            case .closed:
                if self.state == .active || self.state == .reconnecting {
                    self.endReason = .failed; self.hangUp()
                }
            default:
                break
            }
        }
    }
    // Unused delegate methods (required by protocol).
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
