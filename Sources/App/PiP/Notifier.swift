import Foundation
import UserNotifications

// MARK: - 它来找你
//
// ★ 为什么只能走通知：
//   iPhone 上没有任何 App 能从后台凭空弹出浮层 —— 从后台起画中画会被系统
//   当场拒绝（错误原文：The UIScene for the content source has an activation
//   state other than UISceneActivationStateForegroundActive）。
//   通知是**唯一**能压在别人正在用的东西上面自己出现的形式。
//
// ★ 为什么是「提前排好的」而不是「临时想起来的」：
//   小窗不在跑的时候，App 已经被系统冻住了，根本没有临时起意的机会。
//   好在行程表本来就是提前算出来的 —— 把未来几十次「它来找你」的时刻
//   挂成通知，系统自己会准点送到，不需要 App 活着。
//   观感上你分不出「提前排好」和「临时想起」，所以不影响设计。
//
// ★ 通知贴着行程表走，不另掷一套时间：
//   它换房间本来就有自己的节奏，通知挨在这个节奏上，
//   「它从时钟房出来、顺手来找你」才是一件事，而不是两条互不相干的推送。

enum Notifier {

    static let category = "still.summon"
    private static let idPrefix = "still.summon."

    /// 最多挂多少条待发通知。
    /// iOS 对本地待发通知的硬上限是 64 条 —— 留一半余量给以后别的通知（留痕、提醒）。
    static let maxPending = 32

    /// 往后排多远（小时）。
    /// 排得远是有必要的：用户可能十天半月不打开 App，而这段时间 App 根本醒不过来重排。
    static let horizonHours: Double = 240      // 10 天

    /// 它每换一次房间，有多大概率顺手来找你。
    /// 一天挪窝约 11 次 → 一天 3~4 条。这是「它有自己的作息」的一部分，不是推送频率。
    static let summonRate = 0.35

    // MARK: 权限

    static func requestAuthorization(_ done: @escaping (Bool) -> Void = { _ in }) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                DispatchQueue.main.async { done(ok) }
            }
    }

    // MARK: 排期

    /// 重排：先清掉自己以前排的，再按当前行程表排一批新的。
    /// 清是必须的 —— 行程表在换周期时会给出不同的答案，旧的那些会跟新表对不上。
    static func reschedule() {
        clear {
            let items = upcoming(from: Schedule.hourEpoch,
                                 hours: horizonHours,
                                 cap: maxPending)
            guard !items.isEmpty else { return }

            let center = UNUserNotificationCenter.current()
            let name = SharedStore.load().catName ?? "还在"

            for (h, from, to) in items {
                let content = UNMutableNotificationContent()
                content.title = name
                content.body = body(atHour: h, from: from, to: to)
                content.sound = .default
                content.categoryIdentifier = category
                content.userInfo = ["summon": true]
                // 穿透专注模式。它来找你这件小事，值得。
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = category

                let date = Date(timeIntervalSince1970: h * 3600.0)
                let comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

                center.add(UNNotificationRequest(
                    identifier: idPrefix + String(Int(h * 3600)),
                    content: content,
                    trigger: trigger))
            }
        }
    }

    /// 立刻敲一下（测试用）。
    /// 整条链子（通知 → 点 → 小窗）最怕的是「排期排错了」和「起不来」混在一起分不清，
    /// 所以留一个能当场触发的手动入口。
    static func summonNow(after seconds: Double = 5) {
        let content = UNMutableNotificationContent()
        content.title = SharedStore.load().catName ?? "还在"
        content.body = "它在门口"
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["summon": true]
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: idPrefix + "test", content: content, trigger: trigger))
    }

    static func clear(_ done: (() -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
            done?()
        }
    }

    /// 界面上显示用：现在挂着几条等发。
    static func pendingCount(_ done: @escaping (Int) -> Void) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let n = reqs.filter { $0.identifier.hasPrefix(idPrefix) }.count
            DispatchQueue.main.async { done(n) }
        }
    }

    // MARK: 挑时刻

    /// 未来哪些时刻它会来敲你 —— 就挨在「它换房间」的那一刻上。
    /// 返回 (绝对小时, 离开的房间名, 要去的房间名)。
    static func upcoming(from nowHour: Double, hours: Double,
                         cap: Int) -> [(Double, String, String)] {
        var out: [(Double, String, String)] = []
        let end = nowHour + hours
        let seed = SharedStore.loadSeed()

        // 行程表是「一个周期一份」，所以跨周期时要一份一份地取。
        // 少取一份的后果不是报错，是「排到某天就断了」—— 很隐蔽。
        var cycleStart = floor(nowHour / Schedule.cycleHours) * Schedule.cycleHours
        while cycleStart < end && out.count < cap {
            let segs = Schedule.deterministic(atHour: cycleStart + 1, seed: seed)
            for s in segs {
                if s.t1 <= nowHour { continue }
                if s.t1 > end { break }
                if out.count >= cap { break }
                guard wantsToSummon(atHour: s.t1) else { continue }
                // 房间名走 remap：段里写的可能是用户根本没摆的那个组件
                let from = Schedule.remap(s.roomId, atHour: s.t1, segT0: s.t0)
                let to = Schedule.remap(s.nextRoomId, atHour: s.t1, segT0: s.t0)
                out.append((s.t1, roomName(from), roomName(to)))
            }
            cycleStart += Schedule.cycleHours
        }
        return out
    }

    /// 确定性：同一时刻问多少次，答案都一样。
    /// 掷骰子的地方只在「这一刻要不要来」，不在「什么时候来」。
    private static func wantsToSummon(atHour h: Double) -> Bool {
        var r = SeededRandom(seed: FNV.hash("still.summon")
                             ^ UInt32(truncatingIfNeeded: Int(h * 6)))
        return r.next() < summonRate
    }

    private static func body(atHour h: Double, from: String, to: String) -> String {
        let lines = [
            "它从「\(from)」出来了",
            "它想看看你在做什么",
            "它从「\(from)」走开，往「\(to)」去了",
            "它在门口等你一下下",
            "它换了个地方，顺路来找你"
        ]
        let i = Int(FNV.hash("still.body." + String(Int(h * 24))) % UInt32(lines.count))
        return lines[i]
    }

    private static func roomName(_ id: String) -> String {
        Rooms.byId[id]?.name ?? id
    }
}
