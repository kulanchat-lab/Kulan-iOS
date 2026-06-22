import SwiftUI
import AVFoundation

// Playback bubble for a voice note: downloads the encrypted bytes, decrypts them
// (Crypto.decryptBytes), and plays via AVAudioPlayer. Play/pause + progress.
struct VoiceMessageView: View {
    let message: Message
    let cid: String
    let isMe: Bool
    let dark: Bool

    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var loading = false
    @State private var progress: Double = 0
    @State private var timer: Timer?

    private var tint: Color { isMe ? Theme.onAccent(dark) : (dark ? .white : .black) }
    private var durationText: String {
        let d = Int(message.duration ?? 0)
        return String(format: "%d:%02d", d / 60, d % 60)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { toggle() } label: {
                Group {
                    if loading { ProgressView().tint(tint) }
                    else { Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 17)) }
                }
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.3)).frame(height: 3)
                    Capsule().fill(tint).frame(width: max(3, geo.size.width * progress), height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 130, height: 24)

            Text(durationText).font(.caption2).foregroundStyle(tint.opacity(0.8))
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if playing { pause(); return }
        if player != nil { play(); return }
        Task { await load() }
    }

    private func load() async {
        guard let urlStr = message.audioUrl, let url = URL(string: urlStr), let meta = message.enc else { return }
        loading = true
        defer { loading = false }
        guard let (cipher, _) = try? await URLSession.shared.data(from: url),
              let data = await Crypto.shared.decryptBytes(cid, cipher: cipher, meta: meta) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("play-\(message.id).m4a")
        try? data.write(to: tmp)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: tmp)
        play()
    }

    private func play() {
        guard player != nil else { return }
        player?.play()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard let p = player else { return }
            if p.isPlaying {
                progress = p.duration > 0 ? p.currentTime / p.duration : 0
            } else {
                playing = false
                progress = 0
                timer?.invalidate(); timer = nil
                p.currentTime = 0
            }
        }
    }

    private func pause() { player?.pause(); playing = false; timer?.invalidate(); timer = nil }
    private func stop() { player?.stop(); playing = false; timer?.invalidate(); timer = nil }
}
