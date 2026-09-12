import Foundation
import WidgetKit
import ActivityKit

// MARK: - App 与小组件之间的通道
//
// 小组件跑在独立进程里，拿不到主 App 的内存。
// 两边只能靠 App Group 的 UserDefaults 传一张「快照」。
//
// 这也解释了为什么小组件里没有会动的猫：
// 系统给小组件的不是画布，是一张按时刷新的照片。
// 真正的穿梭只能发生在 App 内的桌面画布上。

enum SharedStore {

    static let suiteName = Cfg.appGroup
    static let snapshotKey = "still.snapshot"
    static let scheduleKey = "still.schedule.v2"

    struct Snapshot: Codable {
        var roomId: String
        var sx: Double          // 房间内归一化位置
        var sy: Double
        var z: Float
        var callCount: Int
        var visited: [String]
        var lastSeen: Date
        var catName: String?    // 它叫什么。nil = 还没改过，取默认「还在」
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func save(_ s: Snapshot) {
        guard let d = defaults, let data = try? JSONEncoder().encode(s) else { return }
        d.set(data, forKey: snapshotKey)
        WidgetReloader.reload()
    }

    static func load() -> Snapshot {
        guard let d = defaults,
              let data = d.data(forKey: snapshotKey),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data)
        else {
            return Snapshot(roomId: Rooms.home.id, sx: 0.5, sy: 0.6,
                            z: Cfg.zDefault, callCount: 0, visited: [], lastSeen: Date(),
                            catName: "还在")
        }
        return s
    }

    // MARK: 行程表
    //
    // 这是 App 和小组件之间最重要的东西：唯一性全靠两边读到同一份。
    // key 带版本号 —— 改了 Segment 结构就换一版，免得旧数据解不出来。
    //
    // 行程表本身已经不走这里了（见 Schedule.resolve：确定性现算，谁都能算）。
    // 留着这套存取只为兼容与调试 —— 不要在小组件里依赖它。

    static func saveSchedule(_ segs: [Segment]) {
        guard let d = defaults, let data = try? JSONEncoder().encode(segs) else { return }
        d.set(data, forKey: scheduleKey)
    }

    static func loadSchedule() -> [Segment]? {
        guard let d = defaults,
              let data = d.data(forKey: scheduleKey),
              let s = try? JSONDecoder().decode([Segment].self, from: data),
              !s.isEmpty
        else { return nil }
        return s
    }

    // MARK: 行程表种子
    //
    // 「重置行程」= 换一个种子。
    // ★ 关键是「读不到就用默认」这条规则对 App 和小组件是**对称**的：
    //   两边都调 loadSeed()，抽屉通就都读到新种子，不通就都返回 nil
    //   → 都用默认种子 → 算出来的必然是同一份表（唯一性不崩）。

    static let seedKey = "still.seed.v1"

    static func saveSeed(_ v: UInt32) {
        defaults?.set(Int(v), forKey: seedKey)
    }

    static func loadSeed() -> UInt32? {
        guard let d = defaults, d.object(forKey: seedKey) != nil else { return nil }
        let i = d.integer(forKey: seedKey)
        return i > 0 ? UInt32(i) : nil
    }
}

// MARK: - 触发小组件刷新

enum WidgetReloader {
    // 引擎每次落脚都会 save()，但真去刷小组件太频繁没意义 ——
    // 系统本来就不保证准点，这里 30 秒最多刷一次。
    private static var lastReload = Date.distantPast

    static func reload() {
        let now = Date()
        guard now.timeIntervalSince(lastReload) > 30 else { return }
        lastReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - 灵动岛桥接
//
// 引擎只管「它进岛了 / 出岛了」，ActivityKit 的活儿全在这后面。
// 没有灵动岛硬件（iPhone 14 Pro 之前）时，这里会静默什么都不做。

final class IslandBridge {

    static let shared = IslandBridge()
    private init() {}

    private var activity: Any?
    private var speakTimer: DispatchWorkItem?

    private var supported: Bool {
        guard #available(iOS 16.2, *) else { return false }
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 引擎按行程表把它送进岛时调用（reply = nil，按原样显示房间名）。
    func enter(roomName: String, reply: String? = nil) {
        guard #available(iOS 16.2, *), supported else { return }
        leave()

        let attrs = StillActivityAttributes(roomName: roomName)
        let state = StillActivityAttributes.ContentState(phase: .inside, roomName: roomName, reply: reply)

        do {
            let a = try Activity<StillActivityAttributes>.request(
                attributes: attrs,
                content: .init(state: state, staleDate: Date().addingTimeInterval(60)),
                pushType: nil
            )
            activity = a
        } catch {
            // 灵动岛起不来不该影响主 App —— 静默降级
        }
    }

    /// Siri 聊天：让它从灵动岛里回你一句，不打开 App。
    /// 没有现成活体就新开一个；有就直接更新 ContentState。
    /// 18 秒后自动退场 —— 对话结束，岛交还给行程表驱动的节奏。
    func speak(reply: String, catName: String) {
        guard #available(iOS 16.2, *), supported else { return }
        let state = StillActivityAttributes.ContentState(phase: .inside, roomName: catName, reply: reply)

        if let a = activity as? Activity<StillActivityAttributes> {
            Task { await a.update(using: state) }
        } else {
            let attrs = StillActivityAttributes(roomName: catName)
            do {
                let a = try Activity<StillActivityAttributes>.request(
                    attributes: attrs,
                    content: .init(state: state, staleDate: Date().addingTimeInterval(60)),
                    pushType: nil)
                activity = a
            } catch {
                // 静默降级：岛起不来不影响 Siri 回话本身（语音已经说完）
            }
        }

        speakTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.leave() }
        speakTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 18, execute: t)
    }

    func leave() {
        speakTimer?.cancel()
        speakTimer = nil
        guard #available(iOS 16.2, *) else { return }
        if let a = activity as? Activity<StillActivityAttributes> {
            Task {
                await a.end(using: nil, dismissalPolicy: .immediate)
            }
        }
        activity = nil
    }
}
