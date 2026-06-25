import Foundation
import AVFoundation
import Observation

// Records a voice note to a temp .m4a and hands back the raw bytes + duration +
// a tiny amplitude waveform (captured live via metering — no file re-decode).
// The bytes go through the SAME E2EE pipeline as photos (Crypto.encryptBytes).
@Observable
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?
    var isRecording = false
    var elapsed: TimeInterval = 0
    var levels: [Float] = []          // recent normalized levels (0…1) for the live waveform
    private var allLevels: [Float] = []

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
        recorder?.isMeteringEnabled = true
        recorder?.record()
        fileURL = url
        isRecording = true
        elapsed = 0
        levels = []
        allLevels = []
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            self.elapsed = r.currentTime
            r.updateMeters()
            let level = self.normalize(r.averagePower(forChannel: 0))
            self.allLevels.append(level)
            self.levels.append(level)
            if self.levels.count > 48 { self.levels.removeFirst(self.levels.count - 48) }
        }
    }

    // dBFS (−160…0) → 0…1 with a −50 dB silence floor (Signal's threshold idea).
    private func normalize(_ dB: Float) -> Float {
        let floor: Float = -50
        let clamped = max(floor, min(0, dB))
        return (clamped - floor) / -floor
    }

    // Reduce all captured levels to `count` bars, quantized to 0…100 for compact storage.
    private func waveform(_ count: Int = 40) -> [Int] {
        guard !allLevels.isEmpty else { return [] }
        let per = max(1, allLevels.count / count)
        var bars: [Int] = []
        var i = 0
        while i < allLevels.count && bars.count < count {
            let slice = allLevels[i..<min(i + per, allLevels.count)]
            let avg = slice.reduce(0, +) / Float(slice.count)
            bars.append(Int((avg * 100).rounded()))
            i += per
        }
        return bars
    }

    /// Stop and return (data, duration, waveform). nil if too short or failed.
    func finish() -> (Data, Double, [Int])? {
        timer?.invalidate(); timer = nil
        guard let recorder, let url = fileURL else { reset(); return nil }
        let duration = recorder.currentTime
        recorder.stop()
        let wf = waveform()
        reset()
        guard duration >= 0.5, let data = try? Data(contentsOf: url) else { return nil }
        return (data, duration, wf)
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
        levels = []
        allLevels = []
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
