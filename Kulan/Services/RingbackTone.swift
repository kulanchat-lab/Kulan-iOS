import Foundation

// Generates a US-style ringback tone (440+480 Hz, 2s on / 4s off) as in-memory WAV
// data — so the caller hears "ring… ring…" while waiting, with no bundled asset.
enum RingbackTone {
    static func wavData(sampleRate: Int = 8000) -> Data {
        let total = sampleRate * 6   // one 6s cadence cycle, looped by the player
        var samples = [Int16](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / Double(sampleRate)
            let phase = t.truncatingRemainder(dividingBy: 6.0)
            if phase < 2.0 {   // 2s on, 4s off
                let v = (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t)) / 2
                samples[i] = Int16(max(-1, min(1, v)) * 11000)
            }
        }
        return wav(samples, sampleRate: sampleRate)
    }

    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let dataBytes = samples.count * 2
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataBytes)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(dataBytes))
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }
}
