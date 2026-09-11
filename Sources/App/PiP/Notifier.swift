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

    /// 重排：把未来「它来找你」的时刻挂上去。
    ///
    /// ★★ 顺序是**先挂新的、再清旧的**，不是「先全清、再全排」。
    ///
    ///   清除永远比新增更危险：App 在任何一步都可能被系统当场冻住
    ///   （你切出去的那一刻、小窗刚收掉的那一刻）。
    ///   如果卡在「已经清干净、还没来得及挂」中间，结果就是**一条都不剩** ——
    ///   而那之后 App 醒不过来，再也没机会补，用户看到的就是「它再也不来找我了」。
    ///   现在最坏情况只是「有一条旧的和新的重复」，重复的 id 相同会互相覆盖，
    ///   连这个都不会发生。
    ///
    /// ★ 排查用：每一条的 id 由「它到点的绝对小时」算出来，同一个小时问多少次都一样，
    ///   所以这个函数可以反复调，不会越挂越多。
    static func reschedule() {
        let items = upcoming(from: Schedule.hourEpoch,
                             hours: horizonHours,
                             cap: maxPending)
        let center = UNUserNotificationCenter.current()
        let name = SharedStore.load().catName ?? "还在"
        var keep = Set<String>()

        for (h, from, to) in items {
            let content = UNMutableNotificationContent()
            content.title = name
            content.body = body(atHour: h, from: from, to: to)
            content.sound = .default
            content.categoryIdentifier = category
            content.userInfo = ["summon": true]
            // ★ 不要用 .timeSensitive。
            //   那一档要 Time Sensitive Notifications 这个 capability（entitlement），
            //   而自签重签时它不在描述文件里 —— 跟当初 App Group 是同一类事。
            //   代价只是穿不过专注模式，换来的是「一定会送到」。
            content.interruptionLevel = .active
            content.threadIdentifier = category

            let date = Date(timeIntervalSince1970: h * 3600.0)
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

            let id = idPrefix + String(Int(h * 3600))
            keep.insert(id)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }

        // 再清掉「这次没排上」的旧条目。中途被打断也无所谓 —— 新的已经在上面挂好了。
        center.getPendingNotificationRequests { reqs in
            let stale = reqs.map(\.identifier).filter { $0.hasPrefix(idPrefix) && !keep.contains($0) }
            guard !stale.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
    }

    /// 立刻敲一下（测试用）。
    /// 整条链子（通知 → 点 → 小窗）最怕的是「排期排错了」和「起不来」混在一起分不清，
    /// 所以留一个能当场触发的手动入口 —— 面板上那颗「敲我一下」就是它。
    static func summonNow(after seconds: Double = 5) {
        let content = UNMutableNotificationContent()
        content.title = SharedStore.load().catName ?? "还在"
        content.body = "它在门口"
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["summon": true]
        content.interruptionLevel = .active

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: idPrefix + "test", content: content, trigger: trigger))
    }

    // MARK: 面板诊断
    //
    // 「一条通知都没收到」这件事有四个完全不同的原因，在 App 里长得一模一样：
    //   ① 权限被拒 ② 一条都没挂上 ③ 挂上了但时间算错（在过去的时刻） ④ 挂了但系统没送
    // 分开显示出来，一眼就能砍掉三个。没有这几行的时候只能干等几个小时。

    /// 权限状态，人话版。
    static func authText(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let t: String
            switch s.authorizationStatus {
            case .notDetermined: t = "还没问过"
            case .denied:        t = "被拒了 —— 去 设置→通知→还在 里打开"
            case .authorized:    t = "已允许"
            case .provisional:   t = "临时允许（只进通知中心，不弹）"
            case .ephemeral:     t = "临时"
            @unknown default:    t = "未知"
            }
            DispatchQueue.main.async { done(t) }
        }
    }

    /// 挂着几条 + 下一条什么时候到。
    static func pending(_ done: @escaping (Int, Date?) -> Void) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let mine = reqs.filter { $0.identifier.hasPrefix(idPrefix) }
            let next = mine
                .compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }
                .min()
            DispatchQueue.main.async { done(mine.count, next) }
        }
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
