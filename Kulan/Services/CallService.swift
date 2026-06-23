import Foundation
import Observation
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

    enum State: Equatable { case idle, outgoing, incoming, active, ended }

    var state: State = .idle
    var otherName: String = ""
    var otherPhotoUrl: String?
    private(set) var callId: String?
    private var otherUid: String = ""
    private var isCaller = false

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

    // MARK: - Audio session

    private func configureAudio() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        try? session.setActive(true)
        session.unlockForConfiguration()
    }

    private func makePeerConnection() -> RTCPeerConnection? {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        // Local mic track.
        let audioSource = Self.factory.audioSource(with: nil)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        connection?.add(audioTrack, streamIds: ["stream0"])
        return connection
    }

    // MARK: - Outgoing

    func startCall(to uid: String, name: String, photo: String? = nil) {
        guard state == .idle, !uid.isEmpty else { return }
        isCaller = true
        otherUid = uid
        otherName = name
        otherPhotoUrl = photo
        state = .outgoing
        // CallKit owns the call UI + audio session.
        _ = CallKitManager.shared.startOutgoing(name: name)
        CallKitManager.shared.reportConnecting()

        let ref = db.collection("calls").document()
        callId = ref.documentID
        pc = makePeerConnection()

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc?.offer(for: constraints) { [weak self] sdp, _ in
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
        // Listen for the answer and the callee's ICE candidates.
        observeCallDoc(ref)
        observeRemoteCandidates(ref.collection("calleeCandidates"))
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
                self.callId = doc.documentID
                self.otherUid = d["caller"] as? String ?? ""
                self.otherName = d["callerName"] as? String ?? "Caller"
                let photo = d["callerPhoto"] as? String ?? ""
                self.otherPhotoUrl = photo.isEmpty ? nil : photo
                self.isCaller = false
                self.state = .incoming
                CallKitManager.shared.reportIncoming(name: self.otherName)   // native ringing UI
            }
    }

    func answer() {
        guard state == .incoming, let id = callId else { return }
        let ref = db.collection("calls").document(id)
        pc = makePeerConnection()
        ref.getDocument { [weak self] snap, _ in
            guard let self, let d = snap?.data(),
                  let offer = d["offer"] as? [String: String], let sdp = offer["sdp"],
                  let pc = self.pc else { return }
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
            self.state = .active
        }
    }

    // MARK: - Signalling observers

    private func observeCallDoc(_ ref: DocumentReference) {
        let l = ref.addSnapshotListener { [weak self] snap, _ in
            guard let self, let d = snap?.data() else { return }
            // Caller applies the answer once it arrives.
            if self.isCaller, let answer = d["answer"] as? [String: String], let sdp = answer["sdp"],
               self.pc?.remoteDescription == nil {
                self.pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in }
                self.state = .active
                CallKitManager.shared.reportConnected()
            }
            if (d["status"] as? String) == "ended" { self.cleanup(updateRemote: false) }
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

    func hangUp() { cleanup(updateRemote: true) }

    private func cleanup(updateRemote: Bool) {
        if updateRemote, let id = callId {
            db.collection("calls").document(id).updateData(["status": "ended"])
        }
        CallKitManager.shared.reportEnded()   // clear the system call UI (remote-ended case)
        listeners.forEach { $0.remove() }
        listeners = []
        pc?.close()
        pc = nil
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        callId = nil
        otherUid = ""
        isCaller = false
        state = .ended
        // Drop back to idle shortly so the UI can dismiss.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
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
        if newState == .disconnected || newState == .failed || newState == .closed {
            DispatchQueue.main.async { if self.state == .active { self.hangUp() } }
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
