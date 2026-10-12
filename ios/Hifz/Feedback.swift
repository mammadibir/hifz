import AVFoundation
import UIKit

/// The mistake signal: a real vibration (the web version on iPhone has none) and a short low tone.
final class Feedback {
    private var player: AVAudioPlayer?
    private lazy var tone: Data = Feedback.makeTone()

    func haptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    func beep() {
        do {
            let p = try AVAudioPlayer(data: tone)
            p.volume = 0.9
            p.play()
            player = p
        } catch {}
    }

    /// The same falling triangle tone the page makes: 330 Hz down to 196 Hz in 0.3 s, as 16-bit mono WAV.
    private static func makeTone() -> Data {
        let rate = 44_100.0
        let count = Int(rate * 0.32)
        var samples = [Int16](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / rate
            let freq = 330.0 * pow(196.0 / 330.0, min(t / 0.22, 1.0))
            phase += 2.0 * Double.pi * freq / rate
            let wave = 2.0 / Double.pi * asin(sin(phase))
            let envelope = t < 0.02 ? t / 0.02 : exp(-(t - 0.02) * 14.0)
            let value = max(-1.0, min(1.0, wave * envelope * 0.6))
            samples[i] = Int16(value * 32_767.0)
        }
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(count * 2)
        text("RIFF"); u32(36 + bytes); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        text("data"); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: s)) }
        return data
    }
}
