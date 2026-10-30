import AVFoundation
import Speech
import SwiftUI

// MARK: - 按住小爪说话
//
// 安卓那边一直是「按住说、松手上屏」。iOS 这边以前只有 Siri 短语，
// App 里没有语音输入 —— 这一版补上。
//
// ★ 用它之前必须先把画面和声音让出去（`quiesceForTyping()`）：
//   录音要用音频会话，画中画那条链也在用同一个会话，两边同时抓会互相踩。
//   松手之后 `resumeAfterTyping()` 再还回去 —— 跟打字那条路一模一样。

@MainActor
final class VoiceIn: NSObject, ObservableObject {

    @Published var listening = false
    @Published var heard = ""
    @Published var err: String?
    /// ★ 2026-10-30：当前音量（0…1，真实 RMS）—— 波形用。跟安卓同一个映射。
    @Published var level: Float = 0
    /// 这一句从什么时候开始（判「说话时间太短」）
    private var startedAt = Date.distantPast

    private let audio = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapped = false

    var available: Bool { recognizer?.isAvailable ?? false }

    func start() {
        guard !listening else { return }
        err = nil
        heard = ""

        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                guard st == .authorized else {
                    self.err = "还没允许语音识别 —— 去「设置 → 还在 → 语音识别」打开"
                    return
                }
                AVAudioApplication.requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.err = "还没允许麦克风 —— 去「设置 → 还在 → 麦克风」打开"
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement,
                              options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)

            let input = audio.inputNode
            let fmt = input.outputFormat(forBus: 0)
            guard fmt.sampleRate > 0 else {
                err = "没拿到麦克风（这台机器现在不给录音）"
                return
            }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.taskHint = .dictation
            request = req

            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                req.append(buf)
                // ★ 真实电平：一小块 PCM 的 RMS，映射到 0…1（跟安卓同一条曲线）
                if let ch = buf.floatChannelData?[0] {
                    let n = Int(buf.frameLength)
                    if n > 0 {
                        var sum: Float = 0
                        for i in 0..<n { let v = ch[i]; sum += v * v }
                        let rms = (sum / Float(n)).squareRoot()
                        let lv = min(1, pow(rms * 6, 0.55))
                        DispatchQueue.main.async { self?.level = lv }
                    }
                }
            }
            tapped = true

            audio.prepare()
            try audio.start()
            listening = true
        startedAt = Date()

            task = recognizer?.recognitionTask(with: req) { [weak self] res, e in
                guard let self else { return }
                if let r = res {
                    let t = r.bestTranscription.formattedString
                    DispatchQueue.main.async { self.heard = t }
                }
                if e != nil {
                    DispatchQueue.main.async { self.stopTalking() }
                }
            }
        } catch {
            err = "起不来：\(error.localizedDescription)"
            stopTalking()
        }
    }

    /// 松手：停下、把听到的给它。返回说到的那句。
    @discardableResult
    func stop() -> String {
        let text = heard
        stopTalking()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopTalking() {
        if tapped {
            audio.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if audio.isRunning { audio.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        level = 0
        // 把会话还回去（画中画那边会重新 activate）
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// MARK: - 那颗「按住说话」的小爪

@MainActor
struct PawTalkButton: View {

    /// 说到的那句
    var onSaid: (String) -> Void
    /// 按下 / 松开时让画面和声音让位 / 还回去
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}

    @StateObject private var voice = VoiceIn()
    // ★ 2026-10-30：上滑取消 / 太短提示（对齐安卓）
    @State private var startedAt = Date.distantPast
    @State private var willCancel = false

    var body: some View {
        ZStack {
            Circle()
                .fill(voice.listening ? (willCancel ? Tw.gray400 : Tw.red600) : Tw.gray100)
                .frame(width: 42, height: 42)

            if voice.listening {
                // 12 根真波形（跟着声音高低走；静音时留 5% 底，不然像卡住）
                WaveBars(level: voice.level, tint: Tw.white)
                    .frame(width: 26, height: 18)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
            }
        }
        // 触控区放大到 64（视觉还是 42）—— 手指不用瞄
        .contentShape(Circle().inset(by: -11))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !voice.listening {
                        onDown()
                        voice.start()
                        startedAt = Date()
                        willCancel = false
                    }
                    // 上滑 64pt = 取消
                    willCancel = g.translation.height < -64
                }
                .onEnded { g in
                    let tooShort = Date().timeIntervalSince(startedAt) < 0.6
                    let cancel = g.translation.height < -64
                    let text = voice.stop()
                    SoundKit.shared.tap()
                    onUp()
                    willCancel = false
                    if tooShort {
                        voice.err = "说话时间太短"
                        return
                    }
                    if cancel { return }          // 松手取消：丢弃
                    if !text.isEmpty { onSaid(text) }
                }
        )
    }
}

// MARK: - 12 根真波形

/// 12 根竖条，高度来自真实音量（`VoiceIn.level`）。
/// 静音时保留 5% 底 —— 全 0 看起来像卡住了。
struct WaveBars: View {
    var level: Float
    var tint: Color
    @State private var history: [Float] = Array(repeating: 0, count: 12)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.06)) { _ in
            HStack(alignment: .center, spacing: 1.4) {
                ForEach(0..<12, id: \.self) { i in
                    Capsule()
                        .fill(tint.opacity(0.35 + 0.65 * Double(history[i])))
                        .frame(width: 1.6, height: max(1.2, 18 * CGFloat(0.05 + history[i])))
                }
            }
            .onChange(of: level) { _, v in
                history.removeLast()
                history.insert(max(0.05, v), at: 0)
            }
        }
    }
}
