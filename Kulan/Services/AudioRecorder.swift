import Foundation
import AVFoundation
import Observation

// Records a voice note to a temp .m4a and hands back the raw bytes + duration,
// which then go through the SAME E2EE pipeline as photos (Crypto.encryptBytes).
@Observable
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?
    var isRecording = false
    var elapsed: TimeInterval = 0

    func requestAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.start() }
        }
    }

    private func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        guard recorder != nil else { return }
        recorder?.record()
        fileURL = url
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            self.elapsed = r.currentTime
        }
    }

    /// Stop and return (data, duration). nil if too short or failed.
    func finish() -> (Data, Double)? {
        timer?.invalidate(); timer = nil
        guard let recorder, let url = fileURL else { reset(); return nil }
        let duration = recorder.currentTime
        recorder.stop()
        reset()
        guard duration >= 0.5, let data = try? Data(contentsOf: url) else { return nil }
        return (data, duration)
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        reset()
    }

    private func reset() {
        isRecording = false
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
