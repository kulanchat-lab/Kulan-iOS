import AVKit
import WebRTC

// Native iOS video-call Picture-in-Picture. Detaches the REMOTE feed into a system PiP window
// when the app is backgrounded, so the call keeps showing over the Home Screen / other apps.
//
// IMPORTANT (honesty): this is structurally complete, but the floating window actually showing
// remote video can only be confirmed on a PHYSICAL device in a live 2-party call. The WebRTC
// frame -> CMSampleBuffer path and the PiP lifecycle cannot be verified by a compile alone.
final class CallPiPController: NSObject {
    static let shared = CallPiPController()

    private var controller: AVPictureInPictureController?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var callVC: AVPictureInPictureVideoCallViewController?
    private var renderer: PiPFrameRenderer?
    private weak var attachedTrack: RTCVideoTrack?
    private weak var sourceView: UIView?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    // Idempotent: builds the controller once for a given source view, then just (re)binds the track.
    func configure(sourceView: UIView, remoteTrack: RTCVideoTrack?) {
        guard isSupported else { return }
        if controller == nil || self.sourceView !== sourceView {
            buildController(sourceView: sourceView)
        }
        bind(remoteTrack)
    }

    private func buildController(sourceView: UIView) {
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = UIColor.black.cgColor

        let vc = AVPictureInPictureVideoCallViewController()
        vc.preferredContentSize = CGSize(width: 9, height: 16)
        vc.view.backgroundColor = .black
        displayLayer.frame = vc.view.bounds
        displayLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.layer.addSublayer(displayLayer)
        callVC = vc

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: vc
        )
        let c = AVPictureInPictureController(contentSource: source)
        c.canStartPictureInPictureAutomaticallyFromInline = true   // auto-detaches on background
        c.delegate = self
        controller = c
        self.sourceView = sourceView
    }

    private func bind(_ track: RTCVideoTrack?) {
        if attachedTrack === track { return }
        if let old = attachedTrack, let r = renderer { old.remove(r) }
        renderer = nil
        attachedTrack = track
        guard let track else { return }
        let r = PiPFrameRenderer(layer: displayLayer)
        track.add(r)
        renderer = r
    }

    func teardown() {
        if let old = attachedTrack, let r = renderer { old.remove(r) }
        renderer = nil
        attachedTrack = nil
        controller = nil
        callVC = nil
        sourceView = nil
        displayLayer.flushAndRemoveImage()
    }
}

extension CallPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        print("[PiP] failed to start: \(error.localizedDescription)")
    }
}

// Converts decoded WebRTC frames (the CVPixelBuffer / hardware-decoded path) into CMSampleBuffers
// and feeds them to the PiP display layer. (I420-only frames are skipped — most remote streams
// hardware-decode to a CVPixelBuffer, which this handles.)
final class PiPFrameRenderer: NSObject, RTCVideoRenderer {
    private let layer: AVSampleBufferDisplayLayer
    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer; super.init() }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame,
              let pixelBuffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer,
              let sample = Self.sampleBuffer(from: pixelBuffer) else { return }
        let layer = self.layer
        DispatchQueue.main.async {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
        }
    }

    private static func sampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: formatDesc, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        // Tell the layer to show each frame immediately (live video, not a timed playlist).
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
