import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - 画中画：那一扇一直开着的小窗
//
// 这是 iOS 上**唯一**一个公开的「跨 App 浮层」——
// 猫可以在你刷微信、看视频的时候，还在屏幕角上过自己的日子。
//
// 走的是 playerLayer 内容源（不是 video-call）：我们播的是预合成的片子，
// 形状、缩放、省电全交给系统，比自己摆一块视图稳。
//
// ★ 三条硬限制（系统级，改不了，设计要绕着走）：
//   1. 小窗**不接受透明** —— 所以是一间房，不是一只浮在壁纸上的猫
//   2. 有系统强制的最小尺寸（约两个 App 图标大）—— 小不到「一只猫那么大」
//   3. 小窗里收不到触摸 —— 所以按钮留在 App 里
//
// ★ 一条硬规矩（决定了「它来找你」只能走通知）：
//   后台起不了小窗，系统直接拒。只有两种起法 ——
//   「App 在前台时你点一下」，和「你切出去那一瞬间自动缩下去」。
//   而「点通知」恰好就是把 App 变成前台的那只手，死结是它自己解开的。
//
// 前提（缺一个就静默失效，什么都不报）：
//   · Info.plist 要有 UIBackgroundModes = [audio]
//   · AVAudioSession 必须先 setCategory + setActive(true)，**早于**创建 controller

final class PiPController: NSObject, ObservableObject {

    // MARK: 给界面看的状态

    @Published private(set) var active = false
    @Published private(set) var possible = false
    @Published private(set) var note = "还没接上"
    @Published private(set) var clip = ""
    /// 包里没找到的素材。空 = 正常。
    /// 单独拎出来是因为「资源没打进包」在真机上只表现成**一片黑**，
    /// 编译、运行、日志全都没有任何异常 —— 不主动报出来根本查不到。
    @Published private(set) var missingAssets: [String] = []

    let deviceSupportsPiP = AVPictureInPictureController.isPictureInPictureSupported()

    let cat = CatPlayer()

    /// App 里那间房和小窗里那间，是**同一块图层**的两种呈现，不是两份。
    ///
    /// `layer` 是 v34 的老房型（系统直接放 mp4）；
    /// `displayLayer` 是 v35 的实时流房型（画面我们自己喂）。
    /// 按 `Cfg.liveFramePiP` 只会有其中一块被接上。
    private var layer: AVPlayerLayer?
    private var displayLayer: AVSampleBufferDisplayLayer?

    /// 实时流的帧泵：把播放器的帧取出来 → 画字 → 喂给上面那块图层。
    /// 只在实时流模式下才起。
    private lazy var pump = LiveFramePump(player: cat.player)

    private var pip: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []
    private var didPrepare = false
    private var ticker: Timer?
    private var clipPoll: Timer?

    // MARK: 它跟不跟你 / 什么时候走

    /// 这一趟它跟不跟你出去。
    /// ★ 单向门：小窗一旦停掉，从后台就再也起不来了（系统直接拒）。
    ///   所以这不是一个可以随时反悔的开关，是「它这次没跟」。
    private(set) var following = true

    /// 小窗是什么时候起来的。
    /// ★ 系统在起窗那一刻会顺手调一次 `setPlaying(false)` 来同步状态。
    ///   那是「对表」，不是「他按了」—— 不挡住的话，每次小窗一出来就白弹一条通知。
    private var pipStartedAt = Date.distantPast

    /// 小窗什么时候自己收 —— 就是它「想出去别的房间」了。
    private var closesAt: Date?

    /// 这一次是「点通知叫进来的」—— 小窗一出来就要把自己送回后台。
    private var returnToBackground = false

    /// 全局口子。
    ///
    /// ★ 为什么需要：Siri 在后台唤起 App 跑 Intent 时，拿到的不是界面上那个
    ///   `@StateObject` —— Intent 没有 View，够不到 ContentView 里的实例。
    ///   只有 PiP 在播的时候这个引用才有意义（那时 App 进程是活的）。
    ///   weak：小窗关了、界面销毁了，这里自己变 nil，不会把控制器拴住。
    static weak var shared: PiPController?

    // MARK: - 接口

    /// 被叫了一声：小窗里当场动一下。
    ///
    /// 返回 true = 壳在，画面已经变了；false = 壳不在，得先把壳叫出来。
    /// ★ 这一句不能自己起小窗：后台起小窗系统直接拒（曾遭 -1001），
    ///   必须由调用方先借一次前台，见 `raiseShell()`。
    @discardableResult
    func reactToTalk() -> Bool {
        guard active else {
            note = "它听见了（壳没挂，这一句只在通知里）"
            return false
        }
        cat.react("sit_look", seconds: 6)
        note = "它听见了"
        return true
    }

    /// 壳还没挂上，但这句得演 —— 和起壳同一趟做。
    ///
    /// 为什么不等窗口出来再演：起窗要 0.6~1.4 秒，那时候猫是愣的，
    /// 看起来就像"没听见、白说了"。先让片子在图层里切过去，
    /// 窗口一出来接上的正好是抬头那一下。
    func reactRegardless() {
        // 图层还没接上（App 只是被后台唤起、界面还没起）就别动播放器：
        // 这时候放视频会抢用户正在听的歌，而那一帧根本没有地方显示。
        guard hasSurface else { return }
        cat.react("sit_look", seconds: 6)
        note = "它听见了"
    }

    /// 房间那块图层接上没有（两种房型任一）。
    private var hasSurface: Bool { layer != nil || displayLayer != nil }

    /// App 起来时接一次：把图层交出来，并把屋子里的画面推起来。
    func attach(layer: AVPlayerLayer) {
        // ★ 幂等：SwiftUI 每次刷新都会调过来。重复接会把播放器重新挂一遍，
        //   画面闪一下不说，还可能把正在播的那一帧抖掉。
        if self.layer === layer, layer.player === cat.player { return }
        self.layer = layer
        layer.player = cat.player
        layer.videoGravity = .resizeAspect
        DispatchQueue.main.async { [weak self] in self?.prepare() }
    }

    /// 实时流那条路：接上一块「我们自己喂帧」的图层。
    ///
    /// ★ 这里**不给** layer 设 player —— sample buffer 图层没有 player 这个概念，
    ///   画面全靠帧泵往里喂。播放器仍然在播（解码 + 时间轴），
    ///   但它不再直接连到屏幕上。
    /// ★ 同样幂等：重复 attach 会 flush，画面立刻黑一下 —— 别让它发生。
    func attach(live: AVSampleBufferDisplayLayer) {
        if displayLayer === live { return }
        displayLayer = live
        pump.attach(live)
        pump.start()
        DispatchQueue.main.async { [weak self] in self?.prepare() }
    }

    /// 开始过日子。App 打开 = 它就在这间房（落点之间的穿梭留给后面的版本接）。
    func start() {
        missingAssets = CatPlayer.audit()
        cat.showHere()
        startClipPoll()
    }

    func stop() {
        clipPoll?.invalidate(); clipPoll = nil
        stopTicker()
    }

    // MARK: - 建小窗

    private func prepare() {
        guard !didPrepare else { return }
        guard deviceSupportsPiP else {
            note = "这台设备/系统不支持画中画"
            return
        }
        guard hasSurface else {
            note = "房间还没就位"
            return
        }

        // ② 内容源 —— 两条路二选一，选不出来就别建（建了也是坏的）。
        //
        // ★ 实时流那条：给的是 `AVSampleBufferDisplayLayer` + 一个「播放状态」
        //   委托。系统读不到播放器（这层根本没有 player），所以时间轴、
        //   在播/暂停、快进都得由委托告诉它 —— 见本文件末尾的扩展。
        let source: AVPictureInPictureController.ContentSource
        if Cfg.liveFramePiP, let dl = displayLayer {
            source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: dl, playbackDelegate: self)
        } else if let pl = layer {
            source = AVPictureInPictureController.ContentSource(playerLayer: pl)
        } else {
            note = "房间的图层类型对不上（开关是\(Cfg.liveFramePiP ? "实时流" : "播片")）"
            return
        }

        didPrepare = true

        // ① 音频会话 —— 必须在建 controller 之前。
        //    ★ .mixWithOthers：别把用户正在听的歌掐掉。
        //      小窗自己就有后台资格，不需要靠抢音频通道来续命。
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try s.setActive(true)
        } catch {
            note = "音频会话没起来：\(error.localizedDescription)"
        }

        // 注意签名：`init(contentSource:)` 是**非可失败**的
        //（可失败的只有老的 `init?(playerLayer:)`）。写成 guard let 编不过。
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        applyBareControls(c)

        // ★★★ 这一条 v37 改了，是「切出去不起小窗」的真正修法。
        //
        //   原来写 false，然后在 scenePhase == .background 里手动
        //   `startPictureInPicture()` —— **太晚了**：那一刻 App 已经在后台，
        //   系统直接拒（-1001），而且不弹任何东西。表现就是「划走了，小窗没出来」。
        //
        //   现在交给系统自己接：`canStartPictureInPictureAutomaticallyFromInline`
        //   一开，App 从前台往下沉的**那一瞬**系统就把它接成小窗，
        //   时机由系统把控，不会晚。我们的 `leaveApp()` 只做兜底。
        //
        //   followRate 现在就是 1.0（他定的：一进后台就跟），
        //   所以这个开关恒为 true；哪天要改回「看心情」，这里跟着 followRate 走。
        c.canStartPictureInPictureAutomaticallyFromInline = Cfg.followRate >= 1.0

        pip = c
        note = "就绪 · 切出去它就跟上"

        observations = [
            c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.possible = c.isPictureInPicturePossible
                    if !self.active {
                        self.note = c.isPictureInPicturePossible
                            ? "就绪 · 切出去它就跟上"
                            : "画中画暂时不可用（画面要先在屏幕上）"
                    }
                }
            },
            c.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] c, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.active = c.isPictureInPictureActive
                    if c.isPictureInPictureActive { self.startTicker() } else { self.stopTicker() }
                }
            }
        ]
    }

    // MARK: - 小窗上不要按键

    /// 把小窗里的系统控件藏干净。
    ///
    /// 两条路：
    /// ① `requiresLinearPlayback` —— 官方口子，去掉「前进 / 后退 15 秒」。
    /// ② `controlsStyle` —— 私有 KVC。1 = 只留关闭 / 全屏，2 = 一个不留。
    ///    这条链路是自签侧载、不进 App Store，所以私有 KVC 没有审核风险；
    ///    但系统改版可能把这个 key 抹掉 —— 先问一句 `responds(to:)`，没有就静默跳过，绝不崩。
    private func applyBareControls(_ c: AVPictureInPictureController) {
        // ★★★ v39：**不再用私有 `controlsStyle` 删键。**
        //   它从 v29 一直设成 1（= 只留关闭 / 全屏），结果把「播放 / 暂停」也一起删了 ——
        //   他这次说的「画中画里根本没有这个暂停键」，就是这么来的。
        //   现在只留官方那个口子（去掉快进 / 后退），其余全交回系统画。
        c.requiresLinearPlayback = true
    }

    // MARK: - 手动开关（App 里那两颗按钮）

    func toggle() {
        prepare()
        guard let pip else {
            note = "小窗还没准备好（房间得先在屏幕上）"
            return
        }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
            return
        }
        // ★ 不再「点一下、没反应、什么都不说」。
        //   能起就起；暂时不可起就按 0.25 / 0.6 / 1.2 秒再试三次，
        //   每次都把结果写进 note —— 界面上那行字就是他看到的事实。
        note = "正在把小窗叫出来…"
        startWithRetry([0.0, 0.25, 0.6, 1.2], failNote: "画中画这会儿起不来 —— 房间画面还没在屏幕上稳住")
    }

    // MARK: - 打字的时候先把小窗收起来
    //
    // ★★★ v40：他报「App 里弹出来了但键盘拉不出来，屏幕外那个通知能打」。
    //   两者的差别只有一个：通知那条输入框在**系统进程**里，App 内这条在我们自己的进程里，
    //   而那一刻小窗正开着。小窗在跑的时候，系统会把我们这一侧的键盘压住 ——
    //   要得到键盘，得先让小窗退出去。所以：先收、打完再还。

    /// 收起来去打字。返回「刚才到底开着没有」，打完照这个还回去。
    func parkForTyping() -> Bool {
        guard let p = pip, p.isPictureInPictureActive else { return false }
        p.stopPictureInPicture()
        note = "打字的时候小窗先收一下，打完还给你"
        return true
    }

    /// 打完字把它叫回来。刚才没开就什么都不做。
    func unparkAfterTyping(_ wasOpen: Bool) {
        guard wasOpen else { return }
        guard let p = pip, !p.isPictureInPictureActive else { return }
        startWithRetry([0.4, 1.0, 1.8],
                       failNote: "小窗没叫回来 —— 回 App 点一下「放进小窗」")
    }

    /// 反复尝试起小窗。
    ///
    /// `isPictureInPicturePossible` 是个「会自己变真」的值：图层刚上屏那一两拍
    /// 它还是 false。只试一次就会得到一个假的失败。
    private func startWithRetry(_ delay: [Double], failNote: String) {
        guard let first = delay.first else {
            if !(pip?.isPictureInPictureActive ?? false) { note = failNote }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + first) { [weak self] in
            guard let self, let p = self.pip else { return }
            // 系统自己已经接上了（自动跟随）—— 千万别再插一手，
            // 重复 start 会触发 failedToStart，反而把正在起的小窗打回去。
            if self.active || p.isPictureInPictureActive { return }
            if p.isPictureInPicturePossible {
                p.startPictureInPicture()
            } else {
                self.startWithRetry(Array(delay.dropFirst()), failNote: failNote)
            }
        }
    }

    // MARK: - 你切出去：它决定跟不跟

    /// 切到后台时调一次。
    ///
    /// 跟 → 把小窗放出去，它在角上陪着你。
    /// 不跟 → 什么都不做，桌面干干净净；它想来了会敲你一下（通知）。
    func leaveApp() {
        prepare()
        guard let pip else {
            note = "小窗还没准备好（房间得先在屏幕上）"
            return
        }
        // 已经在跟着了（比如刚点通知进来的）—— 别重算，也别动它
        guard !pip.isPictureInPictureActive else { return }

        following = Self.wantsToFollow()
        guard following else {
            note = "它这次没跟出来 —— 它想来了会敲你一下"
            // 这里**不**重排通知：App 马上要被冻住，异步的「先清后排」
            // 半路被打断的话，结果是一条都不剩。排期统一放在回到前台时做。
            return
        }

        // ★ 走的是兜底：正常情况下系统凭
        //   `canStartPictureInPictureAutomaticallyFromInline` 已经替我们接上了，
        //   这里只是「万一没接上」的那只手。后台调 start 系统可能拒 —— 拒了就算了，
        //   不报错、不打扰，回到前台再重来。
        note = "它跟上来了"
        startWithRetry([0.1, 0.5, 1.2, 2.4], failNote: "小窗没能起来（系统这会儿不让起）")
    }

    /// 你回到 App 里了 —— 小窗该收了。
    ///
    /// 不收的话会**同时有两只猫**（屋里一只、角上一只），
    /// 那正好破了最上面那条：它只在一个地方。
    ///
    /// ★ 但「点通知叫进来的」那一次不算：那一次 App 到前台只是**过路的**，
    ///   小窗正要出来，不能在这一下把它掐掉。
    func backInForeground() {
        guard !returnToBackground else { return }
        guard let pip, pip.isPictureInPictureActive else { return }
        pip.stopPictureInPicture()
    }

    /// 你切出去的那一刻，它决定这一次跟不跟你出去。
    ///
    /// 判据是确定性的（绝对小时 + 固定 seed）：同一个小时里你切出去多少次，
    /// 它的答案都一样。这不是图省事 —— 它的脾气不能自相矛盾，
    /// 否则「它今天没跟」会变成「它每次都阴晴不定」。
    static func wantsToFollow(atHour h: Double = Schedule.hourEpoch) -> Bool {
        // 100% 就直接跟，不用掷 —— 省掉「明明设了 1.0 却因为随机数刚好没中」这种鬼事。
        if Cfg.followRate >= 1.0 { return true }
        if Cfg.followRate <= 0.0 { return false }
        var r = SeededRandom(seed: FNV.hash("still.follow")
                             ^ UInt32(truncatingIfNeeded: Int(h)))
        return r.next() < Cfg.followRate
    }

    // MARK: - 它来找你：点通知进来

    /// 你点了通知 —— 你同意它进来了。
    func summonFromNotification() {
        raiseShell(force: true)
    }

    /// 把壳叫出来。
    ///
    /// ★ 「不走 App 的链路，走壳」就是这一段：Siri 说一句、通知按一下、耳机键按一下，
    ///   都不该先把你拽进房间界面。做法是借一次前台起小窗，小窗一出现立刻把自己送回后台。
    ///   你看到的只是「眼前一闪，它已经在角上了」。
    ///
    /// ★ 为什么不直接说「后台起小窗」不行：iOS 只允许**前台**调 startPictureInPicture，
    ///   后台调一律 -1001。所以「不经过界面」不等于「不经过前台」——
    ///   只能是前台过路一瞬，界面来不及看清就退回去了。
    ///
    /// 顺序是死的：起小窗 → WillStart 里标记 → 0.35 秒后送回后台。
    ///
    /// `force`：点通知那一条要强来。那一次 App 到前台只是**过路的**，
    /// 本来就要出去，不能因为「它现在是 active」就拦下。
    func raiseShell(force: Bool = false) {
        // ★ 人正开着 App 看着它的时候，不该另外再放一只到角上，
        //   更不该为了放壳把人从屋里踢出去。屋顶上那只本来就在屋里。
        if !force && UIApplication.shared.applicationState == .active { return }
        returnToBackground = true
        following = true
        cat.showHere()
        prepare()

        guard deviceSupportsPiP, pip != nil else {
            note = "画中画起不来，这次只能全屏打开"
            return
        }
        note = "你叫它了 —— 它正过来"

        // 起小窗的前提是内容已经准备好（isPictureInPicturePossible）。
        // 留一拍缓冲，正好也是「它从里屋走出来」那一拍。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let pip = self.pip else { return }
            guard !pip.isPictureInPictureActive else { return }
            if pip.isPictureInPicturePossible {
                pip.startPictureInPicture()
            } else {
                // 还不行就再等一拍 —— 冷启动时解码要一点时间。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.pip?.startPictureInPicture()
                }
            }
        }
    }

    // MARK: - 它走了：小窗自己收

    private func startTicker() {
        stopTicker()
        scheduleAutoClose()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        closesAt = nil
    }

    /// 它「想出去别的房间」了。
    ///
    /// 时长是它自己定的（3~14 分钟，按绝对小时确定性掷）—— 这是第 3 条：
    /// 延迟是设计，不是你能调的旋钮。
    private func scheduleAutoClose() {
        var r = SeededRandom(seed: FNV.hash("still.stay")
                             ^ UInt32(truncatingIfNeeded: Int(Schedule.hourEpoch)))
        closesAt = Date().addingTimeInterval(r.range(3.0...14.0) * 60)
    }

    private func tick() {
        guard let closesAt, Date() >= closesAt else { return }
        self.closesAt = nil
        // 先让它走，再收窗 —— 不留一个「它在里面但窗已经关了」的中间态
        cat.showEmpty()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pip?.stopPictureInPicture()
        }
    }

    // MARK: - 把自己送回后台
    //
    // ★ 这是**非公开**写法（社区在用的那一套）。公开接口里没有这个能力 ——
    //   iOS 就是不想让 App 自己溜走。
    //   咱们自签无审核，可以用；万一哪天失效，退回去就是「全屏打开一下」那版，
    //   整个方案不会作废。

    private func sendSelfToBackground() {
        let sel = NSSelectorFromString("suspend")
        guard UIApplication.shared.responds(to: sel) else { return }
        UIControl().sendAction(sel, to: UIApplication.shared, for: nil)
    }

    // MARK: - 界面上显示它在播哪一段

    private func startClipPoll() {
        clipPoll?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = self.cat.currentClip
            if s != self.clip { self.clip = s }
        }
        RunLoop.main.add(t, forMode: .common)
        clipPoll = t
    }
}

// MARK: - 小窗的生命周期

extension PiPController: AVPictureInPictureControllerDelegate {

    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        active = true
        pipStartedAt = Date()
        // 窗口真正出现时系统会把控件重建一遍，这里再压一次。
        applyBareControls(c)
        note = "它在小窗里"
        startTicker()

        // 这一次是「借前台把壳放出来」的 —— 小窗已经出来了，可以把 App 收回后台了。
        // 你原来的事不被打断。
        if returnToBackground {
            returnToBackground = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.sendSelfToBackground()
            }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        active = false
        stopTicker()
        note = possible ? "就绪 · 切出去它就跟上" : "画中画暂时不可用"
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        active = false
        // 这一趟已经结束了，标记要清掉 —— 留着的话，下次你回到 App 里
        // 小窗就不会自己收，会同时出现两只猫。
        returnToBackground = false
        // 最常见的两条：后台起不来（-1001），和画面还没准备好。
        note = "起不来：\(error.localizedDescription)"
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler handler: @escaping (Bool) -> Void) {
        // 用户点小窗上的「还原」—— 不拦，交给系统把 App 带回前台。
        handler(true)
    }
}

// MARK: - 实时流的「播放状态」委托（v35）
//
// ★ 为什么需要这一整块：sample buffer 那一层里**没有播放器对象**，
//   系统无从得知「有多长、在播还是停了」，所以全靠这里告诉它。
//   少实现一个，小窗要么起不来，要么按键一直转圈。
//
// ★ 这一套的定位是「直播」：无限时长、没有暂停、不能跳。
//   正好就是我们要的 —— 猫在过日子，不是一段可以快进的视频。

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {

    /// 直播没有尽头。返回无限时长 ⇒ 系统不画进度条、不显示剩余时间。
    func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    /// 系统会定期来问「现在是暂停状态吗」。
    ///
    /// ★ v38 起恒答「在播」。因为那个键已经不是暂停了 —— 是「跟它说话」。
    ///   答 false，系统就一直画同一个键面（❚❚），按下去永远只做一件事，
    ///   不会出现「按一次是暂停、按两次是播放」这种两个意思混在一个键上。
    func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    /// 用户在小窗上按了那个键。
    ///
    /// ★★ v38：它不再是暂停，是**叫它说话**。
    ///
    ///   为什么不能真暂停：真按暂停之后，系统会把键面换成「播放」，
    ///   再按一下就成了「播放」—— 同一个位置两个意思，越用越乱。
    ///   而且他要的就是「按一下能打字」，不是「按一下停住」。
    ///
    ///   按下去之后**画面照常走**，只在后台发一条带输入框的通知：
    ///   拉下来、写一句、点「说」，全程不离开你正在用的 App。
    func pictureInPictureController(
        _ controller: AVPictureInPictureController, setPlaying playing: Bool
    ) {
        // 起窗那一下系统会调一次 false 来对表，这不是他按的。
        guard !playing else { return }
        guard Date().timeIntervalSince(pipStartedAt) > 1.5 else { return }

        Notifier.askInput()
        note = "小窗上按了一下 —— 通知里等你说一句"
    }

    /// 小窗被捏大捏小了。
    /// 素材只有 720×720 这一档，没有更清晰的可换 —— 什么也不用做，
    /// 系统自己缩放。空实现是协议要求的（不实现编不过）。
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    /// 用户点了「向前/向后跳」。
    ///
    /// ★ v38：这两个键本来是**删掉的**（`requiresLinearPlayback = true`，官方口子，
    ///   见 applyBareControls）。万一某版系统还是把它们画出来，按下去也不能白按 ——
    ///   走同一条路：发一条带输入框的通知。所以他按哪个键，结果都一样。
    ///
    /// ★ 一定要调 completionHandler，不调按键会一直转圈。
    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        Notifier.askInput()
        note = "小窗上按了一下 —— 通知里等你说一句"
        completionHandler()
    }

    /// 不要掐掉后台音频 —— 小窗能一直在后台活着，靠的就是这个资格。
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }
}
