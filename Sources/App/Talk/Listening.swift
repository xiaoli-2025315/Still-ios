import AVFoundation
import Combine
import Foundation
import Speech
import UIKit

// MARK: - 它在听
//
// ★★★ 为什么这条路能成，而「小窗键 → 跑快捷指令」死活不行（2026-10-22 定论）：
//
//   小窗上按一下的那一刻，我们**一定在后台**（前台时小窗根本不存在，两者互斥）。
//   iOS 不给后台 App 打开另一个 App 的资格 —— `UIApplication.open` 调过去会被
//   系统直接丢掉：不执行、不报错、连 completion 都不回调。
//   ⇒ 那条路从设计上就不成立，跟「快捷指令库里有没有那条」**无关**。
//     （他真去库里建了「问它」，按下去仍然没反应，正好证死这一点。）
//
//   而**开麦克风、在后台一直录**是允许的：我们本来就持有 `audio` 后台资格
//   （小窗能活着全靠它）。微信电话挂着的原理一模一样。
//   ⇒ 这条路不唤起任何人，所以碰不到那条死线。
//
// ★ 三个必须让用户知道的代价（苹果强加的，绕不过）：
//   ① 麦克风授权要一次；
//   ② 顶部橙色小点常亮 —— 系统画的，去不掉；
//   ③ 费电。
//
// ★ 断句不靠猜，也不靠长按（那个键根本给不到「松手」事件）。
//   判据只有一条：**最后一声之后安静 0.9 秒**，就当这句说完了。
//   这也是那 1~2 秒延迟的来源 —— 必须等这个安静期过去。
//
// ★ 音量门控：安静时不往识别器里喂数据。
//   不门控的话，空调声、电视声会被断成一句句「字」，半夜自己跟自己聊起来。

/// 帧泵在串行队列上，要读「现在听没听」来画那个小角标。
/// `@Published` 从别的线程读会炸，所以单开一个加锁的格子。
final class ListenFlag {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

final class Listening: ObservableObject {

    static let shared = Listening()

    enum Shape: Equatable {
        case off        // 没在听
        case once       // 听一句，说完自己停
        case always     // 一直听，再按一下关掉
    }

    // MARK: 给界面看

    @Published private(set) var shape: Shape = .off
    /// 它刚把你哪句听成了字（面板上能看见，识别错了立刻就知道）
    @Published private(set) var heard = ""
    /// 小窗上那个键现在是什么状态，一句话
    @Published private(set) var note = "小窗上按一下，就能跟它说话"
    /// 出了岔子才非空（权限没给、麦克风被别的 App 占着…）
    @Published private(set) var problem = ""

    /// 帧泵读这个画角标（跨线程，所以走加锁的格子）
    let flag = ListenFlag()

    // MARK: 内部

    private let micEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    /// 连续「一句都没听清」的次数。用来在识别器彻底抽风时停手，
    /// 别无限重开刷屏 / 刷麦克风。
    private var consecutiveFails = 0

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapOn = false

    /// 这一次是「听一句」还是「一直听」。和 `shape` 分开存：
    /// 连按两下升级成一直听时，发动机不用重启，只翻这个开关。
    private var onceMode = true

    /// 已经叫过 `endAudio`，别重复叫
    private var ending = false

    /// 识别器刚拼出来、还没定稿的字。不走 `@Published`（它在后台线程写）。
    private var partial = ""

    private var lastVoiceAt = Date.distantPast
    private var lastPressAt = Date.distantPast
    private var beganAt = Date.distantPast
    private var lastSent = ""
    private var lastSentAt = Date.distantPast

    private var ticker: Timer?
    private var busy = false
    /// 这一句是否已经交出去（定稿）。兜底定时器靠它判断还需不需要强交。
    private var finalized = false

    /// 静音门限（RMS，0~1）。说话大概 0.02~0.15，安静房间 0.001~0.006。
    /// ★ v73 修正：上一版设成 0.016，但 `voiceChat` 模式自带自动增益会把正常说话的
    ///   音量压到 0.01~0.02 之间 —— 正好被这道门关在门外，识别器收不到声音、
    ///   连续空结果 → 「语音识别这会儿用不了」。降到 0.005：说话稳过，底噪大多仍在门下。
    private static let voiceFloor: Float = 0.005

    /// 苹果单次识别有上限（约一分钟），到点必重开
    private static let reopenAfter: TimeInterval = 55

    /// 最后一声之后安静多久算一句说完
    private static let silenceToEnd: TimeInterval = 0.9

    /// 两次按键间隔小于这个数 = 连按（升级成一直听）
    private static let doubleTap: TimeInterval = 0.7

    private init() {}

    // MARK: - 那个键

    /// 小窗上按了一下。
    ///
    /// 单击：听一句（说完自己停）。
    /// 连按两下：一直听，直到再按一下。
    /// ★ 不标 @MainActor：调用方都在主线程（小窗回调、面板按钮）。
    ///   标了反而要在 DispatchQueue.main 闭包里写 assumeIsolated，徒增一类编译坑。
    func keyPressed() {
        let now = Date()
        let quick = now.timeIntervalSince(lastPressAt) < Self.doubleTap
        lastPressAt = now

        switch shape {
        case .off:
            shape = .once
            onceMode = true
            begin()

        case .once:
            if quick {
                // 升级：发动机本来就在跑，只把「说完就停」摘掉
                shape = .always
                onceMode = false
                note = "一直听着 · 再按一下就关"
            } else {
                // 再要一句：把上一句作废，从头听
                onceMode = true
                note = "再说一句"
                softRestart()
            }

        case .always:
            stop(reason: "不听了")
        }
    }

    /// 面板上那个开关（直接开/关，不用管单击双击）
    func toggleSwitch() {
        if shape == .off {
            shape = .always
            onceMode = false
            begin()
        } else {
            stop(reason: "不听了")
        }
    }

    // MARK: - 开

    private func begin() {
        problem = ""
        let session = AVAudioSession.sharedInstance()

        if session.recordPermission == .denied {
            fail("麦克风被关掉了 —— 去「设置 → 还在」里打开它")
            return
        }
        if session.recordPermission == .undetermined {
            session.requestRecordPermission { ok in
                DispatchQueue.main.async {
                    if ok { self.begin() } else { self.fail("没给麦克风权限，它听不见") }
                }
            }
            return
        }

        // 语音转文字是另一项授权，跟麦克风分开的
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                guard st == .authorized else {
                    self.fail("「语音转文字」没被允许 —— 去设置里打开")
                    return
                }
                do {
                    // 识别期间把猫自己的声音关掉，免得麦克风收进去
                    SoundKit.shared.mute()
                    try self.openEngine()
                } catch {
                    SoundKit.shared.unmute()
                    self.fail("开不了麦克风：\(error.localizedDescription)")
                }
            }
        }
    }

    private func openEngine() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "still.listen", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "这台手机的中文识别这会儿用不了"
            ])
        }

        // ★ 为什么是 `.voiceChat`：它会打开系统自带的回声消除。
        //   不开的话，小窗里它自己的声音会从扬声器出来、被麦克风收回去，
        //   变成「它听见它自己」——半夜自己跟自己聊。
        //   `.defaultToSpeaker` 必须有，不加的话声音改走听筒，小窗就哑了。
        //   ★ 这里**不** deactivate 音频会话：小窗还靠它活着，
        //     只换 category，会话本身一直是激活的。
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat,
                          options: [.defaultToSpeaker, .allowBluetooth])
        try s.setActive(true)

        if !tapOn {
            let input = micEngine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
                throw NSError(domain: "still.listen", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "拿不到麦克风的采样格式"
                ])
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                self?.feed(buf)
            }
            tapOn = true
        }

        micEngine.prepare()
        try micEngine.start()

        startRecognizer()
        flag.value = true
        beganAt = Date()
        note = onceMode ? "听着呢 · 说完就停" : "一直听着 · 再按一下就关"
        startTicker()

        // 换了 category，播放器可能被系统按了一下暂停 —— 让它接着放
        afterSessionChange?()
    }

    /// 音频会话换过之后，让画面继续播（PiPController 接上）
    var afterSessionChange: (() -> Void)?

    // MARK: - 识别

    private func startRecognizer() {
        guard let recognizer else { return }

        task?.cancel()
        task = nil
        ending = false
        finalized = false
        partial = ""
        lastVoiceAt = Date.distantPast

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // ★ 2026-10-22 修正：不再强制离线识别。
        //   离线识别第一次用必须联网下载语言包；画中画里一开就静默失败、
        //   一个字都听不到（前台在线能用、画中画挂，正是这条引起的）。
        //   不设 requiresOnDeviceRecognition 时，系统自己决定：
        //   有网走在线（稳、准），无网且语言包已就绪才走离线。
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.onResult(result, error)
        }
    }

    private func onResult(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
        if let r = result {
            partial = r.bestTranscription.formattedString
            let t = partial
            DispatchQueue.main.async { self.heard = t }
            if r.isFinal {
                finishSentence()
                return
            }
        }
        if error != nil {
            // ★ 正常断句时苹果也会给一个 error（216 / 1110 之类）。
            //   别把它当故障处理 —— 有字就交出去，没字就重开。
            finishSentence()
        }
    }

    /// 一声结束（识别器判的，或者我们判的安静期到了）
    private func finishSentence() {
        guard !busy else { return }
        busy = true
        finalized = true

        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""

        guard !text.isEmpty else {
            busy = false
            consecutiveFails += 1
            if consecutiveFails > 6 {
                fail("语音识别这会儿用不了，稍后再试")
                stop(reason: "语音识别用不了")
                return
            }
            reopen()
            return
        }
        // 同一句连着送两遍（识别器有时会重发 final），拦一下
        if text == lastSent, Date().timeIntervalSince(lastSentAt) < 3 {
            busy = false
            reopen()
            return
        }
        lastSent = text
        lastSentAt = Date()
        consecutiveFails = 0

        DispatchQueue.main.async {
            self.heard = text
            // 听一句：说完就把麦克风关掉（橙点灭、电也省了）
            if self.onceMode {
                self.stop(reason: "听完了")
            }
            self.busy = false
            self.reopen()
            Task { await CatTalk.say(text) }
        }
    }

    /// 把识别器换一条新的（一句话结束 / 到了时间上限 都要换）
    private func reopen() {
        DispatchQueue.main.async {
            guard self.shape != .off else { return }
            self.startedAtReset()
            self.startRecognizer()
        }
    }

    private func startedAtReset() {
        beganAt = Date()
    }

    /// 重新开一句，但麦克风不停（连按换一句时用）
    private func softRestart() {
        DispatchQueue.main.async {
            guard self.shape != .off else { return }
            self.request?.endAudio()
            self.ending = true
            self.startRecognizer()
        }
    }

    // MARK: - 取样

    private func feed(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }

        var sum: Float = 0
        for i in 0..<n {
            let v = ch[i]
            sum += v * v
        }
        let rms = (sum / Float(n)).squareRoot()

        guard rms > Self.voiceFloor else { return }
        lastVoiceAt = Date()
        request?.append(buf)
    }

    // MARK: - 每半秒看一眼

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard flag.value, shape != .off else { return }

        // 单次识别有上限，到点换一条，别等它自己断
        if Date().timeIntervalSince(beganAt) > Self.reopenAfter {
            if !partial.isEmpty {
                finishSentence()
            } else {
                softRestart()
            }
            return
        }

        // 安静够久 → 这一句说完了
        if !ending, !partial.isEmpty,
           Date().timeIntervalSince(lastVoiceAt) > Self.silenceToEnd {
            ending = true
            request?.endAudio()
            // ★ 兜底：画中画/后台里，识别器常在 endAudio 之后不再回调
            //   （系统把后台 App 的语音识别挂起），于是 finishSentence 永不被调用 ——
            //   话送不出去、红点一直亮、猫毫无反应。
            //   1.2 秒后若这一句还没定稿，就拿手里这段 partial 直接交出去。
            // deadline 要的是 DispatchTime，不是 Date（写成 Date 编译不过）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.shape != .off, self.ending, !self.finalized else { return }
                self.finishSentence()
            }
        }
    }

    // MARK: - 关

    func stop(reason: String? = nil) {
        ticker?.invalidate()
        ticker = nil

        ending = true
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil

        if micEngine.isRunning { micEngine.stop() }
        if tapOn {
            micEngine.inputNode.removeTap(onBus: 0)
            tapOn = false
        }

        flag.value = false
        shape = .off
        busy = false
        partial = ""
        note = reason ?? "不听了"

        SoundKit.shared.unmute()

        // ★ 只把 category 换回「放片」，**不** deactivate 会话 ——
        //   小窗要靠这个会话活着，一 deactivate 它就从屏幕上消失了。
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true)

        afterSessionChange?()
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async {
            SoundKit.shared.unmute()
            self.problem = msg
            self.note = msg
            if self.flag.value { self.stop(reason: msg) }
            else { self.shape = .off }
        }
    }

    /// 界面上那一行状态字
    var statusLine: String {
        switch shape {
        case .off:    return "没在听"
        case .once:   return "听着呢 · 说完就停"
        case .always: return "一直听着"
        }
    }
}
