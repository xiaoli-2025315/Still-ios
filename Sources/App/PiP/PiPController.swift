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
    private var layer: AVPlayerLayer?

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

    /// 小窗什么时候自己收 —— 就是它「想出去别的房间」了。
    private var closesAt: Date?

    /// 这一次是「点通知叫进来的」—— 小窗一出来就要把自己送回后台。
    private var returnToBackground = false

    // MARK: - 接口

    /// App 起来时接一次：把图层交出来，并把屋子里的画面推起来。
    func attach(layer: AVPlayerLayer) {
        self.layer = layer
        layer.player = cat.player
        layer.videoGravity = .resizeAspect
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
        guard let layer else {
            note = "房间还没就位"
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

        // ② 内容源 = 那块播放器图层本身。
        let source = AVPictureInPictureController.ContentSource(playerLayer: layer)

        // 注意签名：`init(contentSource:)` 是**非可失败**的
        //（可失败的只有老的 `init?(playerLayer:)`）。写成 guard let 编不过。
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self

        // ★ 自动跟随必须关掉。
        //   我们要的是「它自己决定这次跟不跟」；开着这个开关就等于每次都跟，
        //   那个决定就没地方做了。
        c.canStartPictureInPictureAutomaticallyFromInline = false

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

    // MARK: - 手动开关（App 里那两颗按钮）

    func toggle() {
        prepare()
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
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
        guard pip.isPictureInPicturePossible else {
            note = "画中画这会儿起不来（画面要先在屏幕上）"
            return
        }
        pip.startPictureInPicture()
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
        var r = SeededRandom(seed: FNV.hash("still.follow")
                             ^ UInt32(truncatingIfNeeded: Int(h)))
        return r.next() < 0.78
    }

    // MARK: - 它来找你：点通知进来

    /// 你点了通知 —— 你同意它进来了。
    ///
    /// 顺序是死的：先让 App 到前台（点通知自己完成的），再把小窗放出去，
    /// 然后立刻把自己送回后台。你看到的只是「眼前一闪，它已经在角上了」。
    func summonFromNotification() {
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
        note = "它在小窗里"
        startTicker()

        // 这一次是「点通知叫进来的」—— 小窗已经出来了，可以把 App 收回后台了。
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
