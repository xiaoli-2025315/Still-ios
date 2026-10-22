import AVFoundation
import Foundation

/// 它的声音：脚步 / 起跳 / 落地 / 喵 / 点界面。
///
/// ★ 不从这里碰任何音频会话（AVAudioSession）——
///   App 的音频会话是画中画那条链在管（.playback + active），
///   这里一改 category，小窗的声音和后台保活就可能跟着断。
///   只负责「生成一小段波形 → 放出来」。
///
/// ★ 声音是**合成**的（跟安卓一样，没有打包任何 wav）：
///   一个短的正弦 + 包络，几行就够。合成出来是数据，不是资源文件，
///   不会因为打包漏了而静默没声音。
final class SoundKit {

    static let shared = SoundKit()

    private var players: [String: AVAudioPlayer] = [:]
    private let key = "still.sound.on"

    private init() {
        on = UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    var on: Bool {
        didSet { UserDefaults.standard.set(on, forKey: key) }
    }

    /// v73：识别期间临时把猫自己的声音关掉（不写进设置，结束就恢复），
    /// 免得麦克风把猫的声音收进去、把识别搞乱。
    private var muted = false
    func mute() { muted = true }
    func unmute() { muted = false }

    // MARK: - 给人调的那几个

    func tap() { play("tap", volume: 0.25) }
    func step() { play("step", volume: 0.32) }
    func land() { play("land", volume: 0.45) }
    func jump() { play("jump", volume: 0.4) }
    func meow() { play("meow", volume: 0.6) }

    // MARK: - 播

    private func play(_ name: String, volume: Float) {
        guard on, !muted else { return }
        let p: AVAudioPlayer?
        if let cached = players[name] {
            p = cached
        } else {
            p = make(name)
            players[name] = p
        }
        guard let p else { return }
        p.volume = volume
        p.currentTime = 0
        p.play()
    }

    private func make(_ name: String) -> AVAudioPlayer? {
        let rate = 22050.0
        var samples: [Int16] = []

        switch name {
        case "tap":
            samples = tone(rate: rate, dur: 0.045, f0: 1350, f1: 900, amp: 0.5, decay: 26)

        case "step":
            samples = tone(rate: rate, dur: 0.075, f0: 210, f1: 150, amp: 0.55, decay: 30)

        case "land":
            samples = tone(rate: rate, dur: 0.12, f0: 150, f1: 95, amp: 0.7, decay: 22)

        case "jump":
            samples = tone(rate: rate, dur: 0.13, f0: 320, f1: 620, amp: 0.45, decay: 14)

        case "meow":
            samples = meow(rate: rate)

        default:
            return nil
        }

        guard !samples.isEmpty else { return nil }
        let data = wav(samples, rate: Int(rate))
        return try? AVAudioPlayer(data: data)
    }

    /// 一段带包络的正弦（f0 → f1 滑过去）
    private func tone(rate: Double, dur: Double, f0: Double, f1: Double,
                      amp: Double, decay: Double) -> [Int16] {
        let n = Int(rate * dur)
        var out = [Int16](); out.reserveCapacity(n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let f = f0 + (f1 - f0) * t
            phase += 2 * Double.pi * f / rate
            let env = exp(-decay * t) * (1 - exp(-60 * t))
            let v = sin(phase) * env * amp
            out.append(Int16(max(-1, min(1, v)) * 32000))
        }
        return out
    }

    /// 喵：两个音高 + 一点点颤，收尾拖下去
    private func meow(rate: Double) -> [Int16] {
        let dur = 0.42
        let n = Int(rate * dur)
        var out = [Int16](); out.reserveCapacity(n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(n)
            // 500 → 760 → 430：上来、停一下、落下去，像一声「喵」
            let f: Double
            if t < 0.35 { f = 500 + (760 - 500) * (t / 0.35) }
            else { f = 760 - (760 - 430) * ((t - 0.35) / 0.65) }
            let vib = 1 + 0.02 * sin(2 * Double.pi * 6 * t)
            phase += 2 * Double.pi * f * vib / rate
            let env = sin(Double.pi * min(1, t * 1.15)) * (1 - t * 0.35)
            let v = (sin(phase) * 0.7 + sin(phase * 2) * 0.2) * env * 0.5
            out.append(Int16(max(-1, min(1, v)) * 32000))
        }
        return out
    }

    /// 16bit 单声道 WAV
    private func wav(_ samples: [Int16], rate: Int) -> Data {
        var bytes: [UInt8] = []
        let dataSize = samples.count * 2

        func str(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) {
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 24) & 0xFF))
        }
        func u16(_ v: Int) {
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
        }

        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        str("data"); u32(dataSize)
        for s in samples {
            let v = Int(s)
            u16(v & 0xFFFF)
        }
        return Data(bytes)
    }
}
