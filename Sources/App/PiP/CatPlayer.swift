import AVFoundation
import Foundation

// MARK: - 小窗里放什么：片段表 + 轮播
//
// 为什么是「预合成的视频」而不是「一块活的视图」：
//   小窗不接受透明，画面必须整块铺满 —— 既然要铺满，就得自带一间房。
//   房间和猫一起烘进 mp4，播放器只管播。换来的是「它走 / 它来」能瞬间切换。
//
// 素材怎么来的：D:/素材/动作 里那 16 段 4K 透明动作视频，
// 叠在房间底图上合成 720×720 方片（Tools/_pip_compose.py pack）。
//   → **换房间 = 换底图重新合成**，猫那一套是共用的，不用重做素材。
//
// 这一层只负责「播什么」，不掺任何业务判断 ——
// 「它现在在不在」由 PiPController 说，这里照办。

final class CatPlayer {

    // MARK: 片段表
    //
    // ★ 中文名一律换成英文名再进包。中文名要横跨 Windows → git → macOS 三跳，
    //   任何一处编码不一致都会让 Xcode 找不到资源，而这类故障在真机上
    //   只表现为「画面全黑、日志什么都没有」，极难查。名字在这一层对齐一次就够了。

    /// 「它在这间房」时轮着播的段。
    /// 顺序无所谓 —— 每次随机挑，但**不连着播同一段**（连播看起来像卡住了）。
    static let hereClips = [
        "sit_look",     // 坐着张望
        "groom",        // 舔毛
        "sleep_curl",   // 蜷着睡
        "sleep_flat",   // 趴着睡
        "wake_up",      // 睡醒起身
        "walk",         // 走动
        "hunt1",        // 扑着玩
        "hunt2",
        "roll"          // 翻滚
    ]

    /// ★★★ 2026-10-23：「它走了 —— 只剩一间空房」这段已删。
    ///   他的原话：「IOS 别收窗户，就把空房间的概念去掉」。
    ///   `empty.mp4` **仍然要留在包里** —— 它现在是「房间底图」的来源
    ///   （`LiveFramePump.loadRoomBG` 从它身上抽一帧），只是不再当画面播。
    static let emptyClip = "empty"

    /// 穿进穿出（被拎起 / 悬空）。不进房间轮播 —— 留给以后做落点之间的穿梭动画。
    static let crossClips = ["lifted", "lifted2"]

    // MARK: 状态

    /// 它在这间房。**一旦 true 就不会再变回 false** ——
    /// 小窗里永远有猫（2026-10-23 删掉空房概念后，这里只是「有没有起来过」的意思）。
    private(set) var isHere = false
    /// 此刻这一段的素材名 —— 界面上要看得出它在播哪一段
    private(set) var currentClip = ""
    /// 系统里找不到的素材。收集起来给界面显示，
    /// 否则「包没打进资源」只会表现成一片黑，看不出原因。
    private(set) var missing: [String] = []

    let player = AVQueuePlayer()

    private var currentObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var refilling = false

    /// 被叫了一声：这一刻不轮播，只播指定的那一段。
    /// 没有这个开关，`refill()` 会在切段的瞬间把队列又补满，指定的那段被挤掉。
    private var pinned = false
    private var pinTimer: DispatchWorkItem?
    private var rng = SeededRandom(seed: UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))

    // MARK: 生

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .advance
        // 小窗里继续播（App 切到后台时不跟着停）
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible

        // 两条都挂上，是因为它们各自的时机不一样：
        //   · currentItem 变化 —— 切到下一条的那一刻
        //   · item 播完       —— 队列见底的那一刻（尤其是空房那一段循环时）
        // 只挂一条会在某些接缝上漏掉，表现是「播着播着停住不动了」。
        currentObs = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refill() }
        }
        endObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // 指定播放期间片段会播到头 —— 循环它，别让猫定在最后一帧上。
            // 出去交给 refill 的话，这一趟就变成轮播了，反应就断了。
            if self.pinned {
                if let item = note.object as? AVPlayerItem, item === self.player.currentItem {
                    self.player.seek(to: .zero)
                    self.player.play()
                }
                return
            }
            self.refill()
        }
    }

    deinit {
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 对外

    /// 它在这间房。
    func showHere() {
        guard isHere == false else { return }
        isHere = true
        restart()
    }

    /// 它走了 —— 只剩一间空房。
    ///
    /// ★ 2026-10-23 已删（他的原话：「IOS 别收窗户，就把空房间的概念去掉」）。
    ///   原来它会把 `isHere` 置 false、清掉轮播、切到 `empty` 那段，
    ///   而 iOS 上它只活在画中画里 ⇒ 用户看到的就是「猫没了，只剩屋子」。
    ///   现在没有任何一处会调用它。
    ///   如果以后真要做「它出门」的过场，别从「切空房」做，从一个**看得见的动作**做。

    /// App 刚起来：直接把播放推起来，别等切换。
    func startIfNeeded() {
        if player.items().isEmpty { refill() }
        if player.rate == 0 { player.play() }
    }

    /// 被叫了一声：立刻停下手里的事，看着你。
    ///
    /// 为什么要 `removeAllItems` 而不是「往队尾插一段」：
    /// 队尾插要等当前这段播完才轮到它，而当前这段可能是「睡觉」，一等就是十几秒 ——
    /// 你刚说完话，它十几秒后才抬头，那就不叫反应了。
    ///
    /// seconds 到了就回轮播，观感是「它看了你一会儿，又自己忙去了」。
    func react(_ clip: String = "sit_look", seconds: Double = 6) {
        guard let url = Self.url(for: clip) else {
            // 素材没进包。别静默 —— 记下来给界面上的缺失提示用。
            if !missing.contains(clip) { missing.append(clip) }
            return
        }

        pinTimer?.cancel()

        // 被叫一声，它一定在（不在的话小窗里只有空房，抬头给谁看）
        isHere = true
        pinned = true
        currentClip = clip

        player.pause()
        player.removeAllItems()
        player.insert(makeItem(url), after: nil)
        player.play()

        let t = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pinned = false
            self.pinTimer = nil
            self.restart()
        }
        pinTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: t)
    }

    // MARK: 内部

    /// 建一条片段。**必须走这个口子** ——
    /// 小窗里那行字是挂在 item 的 `videoComposition` 上的，
    /// 直接 `AVPlayerItem(url:)` 建出来的那一条不带字（而且不报错，
    /// 表现就是「别的地方有字、就这段没有」，极难查）。
    ///
    /// ★ 合成器是**每条片段各建一个**的，不能共享 —— 它跟这条片段的视频轨
    ///   绑死，挂到别的 asset 上会直接崩。详见 SayBubble.swift 文件头。
    /// ★ 拿不到视频轨就不挂：没字只是难看，崩了是 App 打不开。
    /// ★★★ v34：`Cfg.bubbleInPiP` 关着时**根本不碰 videoComposition**。
    ///   连着两版（v32/v33）都因为这条链「点开就闪退」，先退回 v31 的播法。
    ///   开关一开，这里的代码原样生效 —— 上面的三条注意事项都还有效。
    private func makeItem(_ url: URL) -> AVPlayerItem {
        let it = AVPlayerItem(url: url)
        guard Cfg.bubbleInPiP else { return it }
        if let c = SayBubble.shared.composition(for: it.asset) {
            it.videoComposition = c
        }
        return it
    }

    private func restart() {
        player.pause()
        player.removeAllItems()
        refill()
        player.play()
    }

    /// 把队列补到 2 条。
    /// 为什么是 2 而不是 1：一条播完队列就空了，AVQueuePlayer 会停在原地 ——
    /// 留一条在队里，切歌才是无缝的。
    private func refill() {
        // 指定播放期间不许补队列 —— 补了就会把「看着你」这一段挤掉。
        guard !pinned else { return }
        guard !refilling else { return }
        refilling = true
        defer { refilling = false }

        let want = 2
        var tries = 0
        while player.items().count < want && tries < 6 {
            tries += 1
            let name = pick()
            guard let url = Self.url(for: name) else {
                if !missing.contains(name) { missing.append(name) }
                return
            }
            let item = makeItem(url)
            if player.items().isEmpty { currentClip = name }
            player.insert(item, after: nil)
        }
        if player.rate == 0 { player.play() }
    }

    private func pick() -> String {
        let pool = Self.hereClips
        // ★ 2026-10-23：原来这里有一句「不在就播空房」，现在猫永远在场，已删。
        guard !pool.isEmpty else { return Self.emptyClip }
        var name = pool[rng.int(pool.count)]
        // 别连着播同一段
        if name == currentClip, pool.count > 1,
           let i = pool.firstIndex(of: name) {
            name = pool[(i + 1) % pool.count]
        }
        return name
    }

    /// 素材在 bundle 里的位置 —— 三种可能的层级都试一遍。
    ///
    /// ★ 看着啰嗦，防的是一类极难查的故障：mp4 被放错层级时编译照样通过，
    ///   真机上只有一片黑，日志什么都没有。宁可多试两次。
    static func url(for name: String) -> URL? {
        let b = Bundle.main
        if let u = b.url(forResource: name, withExtension: "mp4") { return u }
        if let u = b.url(forResource: name, withExtension: "mp4", subdirectory: "pip") { return u }
        if let u = b.url(forResource: "pip/\(name)", withExtension: "mp4") { return u }
        return nil
    }

    /// 自检：素材到底进包没有。装在手机上第一眼看这个，比看画面猜快得多。
    static func audit() -> [String] {
        (hereClips + [emptyClip] + crossClips).filter { url(for: $0) == nil }
    }
}
