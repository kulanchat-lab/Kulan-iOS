import SwiftUI
import WebRTC

// Renders a WebRTC video track (local preview or the remote feed) via Metal.
// `mirror` flips horizontally for the local front camera (selfie view).
struct VideoRendererView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirror: Bool = false

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.transform = mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        // Re-bind only when the track actually changes (attaching twice double-renders).
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(uiView)
            track?.add(uiView)
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(uiView)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var track: RTCVideoTrack? }
}
