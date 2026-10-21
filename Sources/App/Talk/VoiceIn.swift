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

            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
                req.append(buf)
            }
            tapped = true

            audio.prepare()
            try audio.start()
            listening = true

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

    var body: some View {
        ZStack {
            Circle()
                .fill(voice.listening ? Tw.red600 : Tw.gray100)
                .frame(width: 42, height: 42)
            Image(systemName: voice.listening ? "waveform" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(voice.listening ? Tw.white : Tw.gray900)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !voice.listening {
                        onDown()
                        voice.start()
                    }
                }
                .onEnded { _ in
                    let text = voice.stop()
                    SoundKit.shared.tap()
                    onUp()
                    if !text.isEmpty { onSaid(text) }
                }
        )
    }
}
