import Foundation
import SwiftUI

// MARK: - 引擎
//
// ⚠️ 行程表不在引擎里生成，统一走 Schedule（Sources/App/Shared/Schedule.swift）。
//    原因：小组件跑在独立进程，它必须能独立回答「它现在在哪」，
//    而唯一性要求两边读到的是**同一份**行程表。引擎只负责「照着行程表演」。

@MainActor
final class PetEngine: ObservableObject {

    // ── 发布给 UI ─────────────────────────────────────────────
    @Published private(set) var roomId: String
    @Published private(set) var page: Int
    @Published private(set) var pos: CGPoint          // 桌面归一化坐标（走路时可能超出 0...1）
    @Published private(set) var z: CGFloat            // 纵深 0=跟前 1=深处
    @Published private(set) var state: PetState
    @Published private(set) var act: Act
    @Published private(set) var isWalking: Bool
    @Published private(set) var inIsland: Bool
    @Published private(set) var visited: Set<String>
    @Published private(set) var facing: CGFloat = 1   // 1 朝右，-1 朝左
    @Published private(set) var actLog: [Act] = []
    @Published private(set) var catName: String = "还在"
    @Published var speed: Double = 300                // 演示倍速
    @Published var hoursNow: Double = 0               // 相对真实现在的小时偏移（0=现在）

    // 扑击：视图层监听这个，抖一下被扑的组件
    @Published private(set) var huntingRoomId: String?

    // ── 内部 ─────────────────────────────────────────────────
    private var schedule: [Segment] = []
    private var curSeg: Segment?
    private var rnd = SeededRandom(seed: 0x5D111)

    private var from = CGPoint.zero
    private var to = CGPoint.zero
    private var fromZ: CGFloat = 0
    private var toZ: CGFloat = 0
    private var animStart = Date()
    private var animDur: Double = 1
    private var pageSwitchAt: Double = -1     // 走路进度到多少时翻页（<0 = 同页，不用翻）
    private var fromPage = 0
    private var targetPage = 0
    private var pendingRoomId: String?
    private var switched = false

    private var actDeadline = Date()
    private var actGen = 0
    private var isFirstAct = true

    private var timer: Timer?
    private var lastTick = Date()

    private var callCount = 0

    // MARK: 现在几点（小时）
    private static var hourEpoch: Double { Date().timeIntervalSince1970 / 3600.0 }

    // MARK: - 启动

    init() {
        let store = SharedStore.load()
        roomId = store.roomId
        page = Rooms.byId[store.roomId]?.page ?? 0
        z = CGFloat(store.z)
        callCount = store.callCount
        visited = Set(store.visited)
        catName = store.catName ?? "还在"
        state = .idle
        act = .sit
        isWalking = false
        inIsland = false
        pos = PetEngine.deskPos(roomId: store.roomId, spotInRoom: CGPoint(x: store.sx, y: store.sy))
        from = pos; to = pos; fromZ = z; toZ = z

        schedule = Schedule.ensure()
        syncToNow()
    }

    func start() {
        stop()
        lastTick = Date()
        // 用 Timer(timeInterval:repeats:) 而不是 scheduledTimer，
        // 否则下面再 add(to:forMode:) 一次就等于加了两遍，tick 频率翻倍。
        let t = Timer(timeInterval: 1.0 / Cfg.tickHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - 行程表
    //
    // 行程表由 Schedule 统一生成并持久化（App Group），这里只做查询和续期。
    // 引擎**绝不改写**行程表 —— 那是唯一性的前提，见 Schedule.swift 顶部注释。

    private func seg(atHour h: Double) -> Segment? {
        Schedule.segment(schedule, atHour: h)
    }

    /// 任意时刻它在哪儿。时间机器靠这个，小组件也靠同一个函数。
    func whereAt(hourOffset h: Double) -> String {
        Schedule.place(schedule, atHour: Self.hourEpoch + h).roomId ?? Rooms.home.id
    }

    // MARK: - 时间推进

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        if isWalking {
            stepWalk(now: now)
        } else {
            // 走路的时候时间不推进：走就是走，几秒就是几秒
            hoursNow += dt * speed / 3600.0

            // 快走到行程表末尾了就往后续一段（只追加，绝不重写已有的段）
            Schedule.extendIfNeeded(&schedule)

            let h = Self.hourEpoch + hoursNow
            if let s = seg(atHour: h), s.t0 != curSeg?.t0 {
                // 时段翻篇了 —— 它自己起身换地方
                curSeg = s
                moveTo(s.nextRoomId, islandHours: s.islandHours)
            }
            // 岛是行程表里的一个「地方」，和组件同级
            syncIsland(atHour: h)

            // 动作循环
            if now >= actDeadline { nextAct() }
        }
    }

    /// 把引擎对齐到「现在」
    private func syncToNow() {
        hoursNow = 0
        guard let s = seg(atHour: Self.hourEpoch) else { return }
        curSeg = s
        roomId = s.roomId
        page = Rooms.byId[roomId]?.page ?? 0
        let spot = Rooms.byId[roomId]?.spot ?? .init(x: 0.5, y: 0.6)
        pos = Self.deskPos(roomId: roomId, spotInRoom: spot)
        from = pos; to = pos; toZ = z; fromZ = z
        isWalking = false
        inIsland = false
        startIdleLoop()
    }

    // MARK: - 坐标

    /// 房间内归一化坐标 → 桌面归一化坐标（4 列 × 6 行网格）
    static func deskPos(roomId: String, spotInRoom s: CGPoint) -> CGPoint {
        guard let r = Rooms.byId[roomId] else { return CGPoint(x: 0.5, y: 0.5) }
        let cw = 1.0 / 4.0, rh = 1.0 / 6.0
        return CGPoint(x: Double(r.col - 1) * cw + Double(s.x) * Double(r.w) * cw,
                       y: Double(r.row - 1) * rh + Double(s.y) * Double(r.h) * rh)
    }

    static func frame(roomId: String) -> CGRect {
        guard let r = Rooms.byId[roomId] else { return .zero }
        let cw = 1.0 / 4.0, rh = 1.0 / 6.0
        return CGRect(x: Double(r.col - 1) * cw,
                      y: Double(r.row - 1) * rh,
                      width: Double(r.w) * cw,
                      height: Double(r.h) * rh)
    }

    // MARK: - 换地方

    /// 它自己起身，走到另一个组件里去
    ///
    /// islandHours 只是带过来备用：真正进不进岛由 syncIsland() 按行程表判断，
    /// 因为岛的进出还可能发生在「它没挪窝、只是从岛上下来」的时候。
    func moveTo(_ targetId: String, islandHours: Double) {
        guard let tgt = Rooms.byId[targetId] else { return }
        let destSpot = tgt.spot
        let dest = Self.deskPos(roomId: targetId, spotInRoom: destSpot)

        from = pos
        to = dest
        fromZ = z
        toZ = CGFloat(Self.roamZ())
        pendingRoomId = targetId

        var dist = abs(dest.x - from.x) + abs(dest.y - from.y)
        fromPage = page

        if tgt.page == page {
            // 同页：直接走过去
            targetPage = page
            pageSwitchAt = -1
        } else {
            // 跨页：先横向窜出屏幕边缘，翻页，再从另一侧走进来
            targetPage = tgt.page
            pageSwitchAt = 0.42
            dist += 0.35
        }

        animDur = (dist + Double(abs(toZ - fromZ)) * Double(Cfg.depthCost)) * Cfg.walkSecPerUnit
        animDur = animDur.clamped(Cfg.walkSecMin, Cfg.walkSecMax)
        animStart = Date()
        switched = false
        facing = dest.x >= from.x ? 1 : -1
        state = .walk
        isWalking = true
        inIsland = false
        stopIdleLoop()
    }

    /// 它自己在纵深上挑一个落点：平方分布，多数时候待在近处，偶尔退进深处
    private static func roamZ() -> Float {
        let f = Float.random(in: 0...1)
        return Cfg.zNear + (Cfg.zFar - Cfg.zNear) * f * f
    }

    private func stepWalk(now: Date) {
        let t = (now.timeIntervalSince(animStart) / animDur).clamped(0, 1)

        if pageSwitchAt > 0 && !switched && t >= pageSwitchAt {
            switched = true
            page = targetPage
        }

        if pageSwitchAt > 0 {
            // 跨页：先窜出屏幕边缘，翻页，再从另一边走进来
            let goingRight = targetPage > fromPage
            let exitX: CGFloat  = goingRight ? 1.25 : -0.25
            let entryX: CGFloat = goingRight ? -0.25 : 1.25
            let yMid = from.y + (to.y - from.y) * 0.3

            if t < pageSwitchAt {
                let k = t / pageSwitchAt
                pos = CGPoint(x: from.x + (exitX - from.x) * k,
                              y: from.y + (yMid - from.y) * k)
            } else {
                let k = (t - pageSwitchAt) / max(1 - pageSwitchAt, 0.001)
                pos = CGPoint(x: entryX + (to.x - entryX) * k,
                              y: yMid + (to.y - yMid) * k)
            }
        } else {
            // 同页：直线走过去，中间稍微提一点 —— 像迈过去，不是滑过去
            let lift = -sin(t * .pi) * 0.012
            pos = CGPoint(x: from.x + (to.x - from.x) * t,
                          y: from.y + (to.y - from.y) * t + lift)
        }

        z = fromZ + (toZ - fromZ) * t

        if t >= 1 {
            isWalking = false
            state = .idle
            if let pending = pendingRoomId { roomId = pending; pendingRoomId = nil }
            page = Rooms.byId[roomId]?.page ?? page
            visited.insert(roomId)
            pos = to

            // 走到了，重新取一次当前时段（此时已经进入新的一段），
            // 再按行程表决定它是不是该在岛上。
            let h = Self.hourEpoch + hoursNow
            curSeg = seg(atHour: h) ?? curSeg
            syncIsland(atHour: h)
            startIdleLoop()
            save()
        }
    }

    // MARK: - 灵动岛
    //
    // 岛是行程表里的一个「地方」，和 16 个组件同级。
    // 它在岛里的那段时间，任何组件都不画猫 —— 这是唯一性的一部分。

    private func syncIsland(atHour h: Double) {
        let want = Schedule.place(schedule, atHour: h).isIsland
        if want && !inIsland {
            enterIsland()
        } else if !want && inIsland {
            exitIsland()
        }
    }

    private func enterIsland() {
        inIsland = true
        IslandBridge.shared.enter(roomName: Rooms.byId[roomId]?.name ?? "")
        actGen += 1
        act = .sit
        actDeadline = Date()      // 立刻走一次动作循环
    }

    private func exitIsland() {
        inIsland = false
        IslandBridge.shared.leave()
        startIdleLoop()
    }

    // MARK: - 待着的时候在干什么

    private func startIdleLoop() {
        actGen += 1
        isFirstAct = true
        nextAct()
    }

    private func stopIdleLoop() {
        actGen += 1
        huntingRoomId = nil
    }

    private func nextAct() {
        guard !isWalking else { return }

        // 岛上地方小，只做安静的小动作。
        // 每次换姿势都会触发一次系统的岛过渡动画 —— 这是岛比组件好看的地方：
        // 组件是死图，岛上的它是会动的。
        if inIsland {
            act = [Act.sit, .look, .groom][Int.random(in: 0...2)]
            state = .idle
            actDeadline = Date().addingTimeInterval(Double.random(in: 5.0...11.0))
            return
        }

        let gen = actGen
        let a: Act = isFirstAct ? .look : pickAct()
        isFirstAct = false
        act = a
        state = (a == .sleep) ? .sleep : .idle

        actLog.append(a)
        if actLog.count > 5 { actLog.removeFirst() }

        if a == .hunt { playHunt(gen: gen) }

        let base = Cfg.actSec[a] ?? 3.0...5.0
        let ms = Double.random(in: base) * (isFirstAct ? 0.6 : 1.0)
        actDeadline = Date().addingTimeInterval(ms)
    }

    /// 刚到一个新地方先抬头看看，再决定干嘛
    private func pickAct() -> Act {
        let r = Double.random(in: 0...1)
        switch act {
        case .sleep:   return r < 0.42 ? .stretch : (r < 0.78 ? .groom : .sit)
        case .hunt:    return r < 0.56 ? .sit : .groom
        case .stretch: return r < 0.44 ? .groom : (r < 0.70 ? .hunt : .sit)
        default:
            // 睡觉占大头 —— 它大部分时间应该是安静的，不是一直在动
            return r < 0.30 ? .sleep
                 : r < 0.48 ? .groom
                 : r < 0.60 ? .look
                 : r < 0.67 ? .stretch
                 : r < 0.76 ? .hunt
                 : .sit
        }
    }

    /// 扑组件里的东西 —— 扑到了，那个组件会抖一下
    private func playHunt(gen: Int) {
        let id = roomId
        // 蹲 1.15 秒盯住，然后扑 —— 扑到了，那个组件会抖一下
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
            guard let self, gen == self.actGen else { return }
            self.huntingRoomId = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, gen == self.actGen else { return }
                self.huntingRoomId = nil
            }
        }
    }

    // MARK: - 呼唤 / NFC
    //
    // ⚠️ 这两个操作**都不改变它在哪个房间**，只改变它在那个房间里的远近。
    //
    // 为什么：桌面小组件显示的是行程表，而行程表一旦下发就不可改写
    // （改了就会出现「两个组件同时有猫」，见 Schedule.swift 顶部）。
    // 让你喊一嗓子就把它从一个房间拽到另一个房间，等于要改写行程表。
    //
    // 所以「喊它」的语义变成：**它从房间深处走到你跟前**。
    // 这反而更贴它 —— 它不是挂件，你叫它，它靠近你，但不会瞬移。

    /// 概率召回：喊了不一定来。true = 它过来了
    @discardableResult
    func call() -> Bool {
        callCount += 1
        save()
        guard Double.random(in: 0...1) < Cfg.recallRate else { return false }

        // 它是从房间深处走到你跟前的：喊一声，它会明显走近
        let near = max(CGFloat(Cfg.zNear), min(z, 1) * 0.45)
        walkTo(pos: Self.spotNearFront(roomId: roomId), z: near)
        startIdleLoop()
        return true
    }

    /// NFC 牌是物理保证：碰了必回。
    /// 「必回」= 它一定会走到你面前（100%，不是 68%），并且是最贴近你的距离。
    func nfcRecall() {
        callCount = 0
        walkTo(pos: Self.spotNearFront(roomId: roomId), z: CGFloat(Cfg.zNear))
        startIdleLoop()
        save()
    }

    /// 房间内靠近下沿的位置 —— 相当于「走到你眼前」，而不是房间正中
    private static func spotNearFront(roomId: String) -> CGPoint {
        Rooms.byId[roomId].map { _ in Self.deskPos(roomId: roomId, spotInRoom: CGPoint(x: 0.5, y: 0.78)) }
            ?? CGPoint(x: 0.5, y: 0.62)
    }

    private func walkTo(pos p: CGPoint, z nz: CGFloat) {
        from = pos
        to = p
        fromZ = z
        toZ = nz.clamped(0, 1)
        pendingRoomId = roomId
        let dist = abs(p.x - from.x) + abs(p.y - from.y) + abs(toZ - fromZ) * CGFloat(Cfg.depthCost)
        animDur = Double(dist) * Cfg.walkSecPerUnit
        animDur = animDur.clamped(Cfg.walkSecMin, Cfg.walkSecMax)
        animStart = Date()
        switched = false
        fromPage = page
        pageSwitchAt = -1
        targetPage = page
        facing = p.x >= from.x ? 1 : -1
        state = .walk
        isWalking = true
        inIsland = false
        stopIdleLoop()
    }

    // MARK: - 双指拎远近

    /// 你定的是「它这会儿在哪儿」，不是锁死一个值 —— 松手后它接着自己走
    func setDepth(_ nz: CGFloat, persist: Bool) {
        let v = nz.clamped(0, 1)
        fromZ = v; toZ = v; z = v
        if persist {
            actDeadline = Date().addingTimeInterval(4.0)   // 别你刚放下它就走开
            save()
        }
    }

    /// 给它起名。空名回退到「还在」。Siri 唤醒词里用的就是它。
    func setName(_ n: String) {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        catName = t.isEmpty ? "还在" : t
        save()
    }

    // MARK: - 时间机器

    func seek(hoursOffset h: Double) {
        let id = whereAt(hourOffset: h)
        hoursNow = h
        curSeg = seg(atHour: Self.hourEpoch + h)
        roomId = id
        page = Rooms.byId[id]?.page ?? 0
        pos = Self.deskPos(roomId: id, spotInRoom: Rooms.byId[id]?.spot ?? .init(x: 0.5, y: 0.6))
        from = pos; to = pos
        isWalking = false
        inIsland = false
        // 注意：schedule 的 t 是绝对小时，hoursNow 是相对偏移，比较时要加回去
        let abs = Self.hourEpoch + h
        visited = Set(schedule.filter { $0.t1 <= abs }.map { $0.roomId })
        startIdleLoop()
    }

    /// 手动翻页（点某个组件去看那一页）—— 只挪你的视点，不动它的行程
    func showPage(_ p: Int) {
        guard !isWalking else { return }     // 它正走着，别把镜头拽走
        page = p.clamped(0, Rooms.pageCount - 1)
    }

    /// 跳到它下次挪窝：把时间推到当前时段末尾
    func jumpToNextMove() {
        guard let s = curSeg else { return }
        hoursNow += (s.t1 - (Self.hourEpoch + hoursNow))
        hoursNow += 0.0001
        moveTo(s.nextRoomId, islandHours: s.islandHours)
    }

    func reset() {
        hoursNow = 0
        visited = []
        callCount = 0
        schedule = Schedule.reset()
        syncToNow()
        save()
        WidgetReloader.reload()      // 行程表换了，让桌面尽快跟上
    }

    // MARK: - 撞见概率
    /// 它一天走多久、你一天看多少次手机 —— 两者撞上的机会
    func chanceSummary() -> (perDay: Double, days: Double) {
        let avgStay = (Cfg.stayHoursMin + Cfg.stayHoursMax) / 2.0
        let movesPerDay = 24.0 / avgStay
        let walkSecPerDay = movesPerDay * 4.5
        let glancesPerDay = 80.0
        let p = 1 - pow(1 - walkSecPerDay / 86400.0, glancesPerDay)
        return (p, p > 0 ? 1 / p : 999)
    }

    // MARK: - 持久化

    func save() {
        let spot = Rooms.byId[roomId]?.spot ?? .init(x: 0.5, y: 0.6)
        SharedStore.save(SharedStore.Snapshot(
            roomId: roomId,
            sx: Double(spot.x), sy: Double(spot.y),
            z: Float(z),
            callCount: callCount,
            visited: Array(visited),
            lastSeen: Date(),
            catName: catName
        ))
    }
}
