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

    /// 「它走了」—— 只剩一间空房。空房不是没画面，是「只有房间、没有猫」。
    static let emptyClip = "empty"

    /// 穿进穿出（被拎起 / 悬空）。不进房间轮播 —— 留给以后做落点之间的穿梭动画。
    static let crossClips = ["lifted", "lifted2"]

    // MARK: 状态

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
        ) { [weak self] _ in
            self?.refill()
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
    func showEmpty() {
        guard isHere == true else { return }
        isHere = false
        restart()
    }

    /// App 刚起来：直接把播放推起来，别等切换。
    func startIfNeeded() {
        if player.items().isEmpty { refill() }
        if player.rate == 0 { player.play() }
    }

    // MARK: 内部

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
            let item = AVPlayerItem(url: url)
            if player.items().isEmpty { currentClip = name }
            player.insert(item, after: nil)
        }
        if player.rate == 0 { player.play() }
    }

    private func pick() -> String {
        guard isHere, !Self.hereClips.isEmpty else { return Self.emptyClip }
        let pool = Self.hereClips
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
