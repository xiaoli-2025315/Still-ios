import Foundation

// MARK: - 它叫什么（全工程唯一一份）
//
// ★★★ 2026-10-21 为什么要单独拎出来：
//
//   原来名字只存在 `SharedStore` 那张快照里，而快照住在 **App Group** 的
//   UserDefaults 里（`UserDefaults(suiteName: Cfg.appGroup)`）。App Group 的权限
//   写在 entitlements 里，**重签有丢的可能**。一旦丢了：
//     · `UserDefaults(suiteName:)` 在 iOS 上取不到 → 整个快照读不出来
//     · `SharedStore.load()` 就走默认值 → catName = 「还在」
//   结果就是「用户明明起了名字，Siri 只认还在」。
//
//   而 Siri 这条链根本**不需要跨进程**：指令写在主 App 里、openAppWhenRun=false，
//   系统在后台把**同一个 App 进程**拉起来跑。所以名字完全可以存在 App 自己的沙盒
//   （UserDefaults.standard）里 —— 同一个进程、同一个沙盒，一定读得到，
//   跟签名方式、跟 App Group 在不在，全都无关。
//
//   两层这么排：
//     ① standard（主）—— 立刻读得到，Siri 用它
//     ② App Group 快照（兜底）—— 老版本留下的、以及小组件/灵动岛要用的那份
//
//   这样重签就算把 App Group 弄丢了，Siri 叫的还是用户起的那个名字。

enum PetName {

    /// 存在 App 自己沙盒里的键。带前缀免得跟别的偏好撞。
    static let key = "still.petName"

    /// 没起过名字时叫它什么。
    static let fallback = "还在"

    /// 去掉首尾空白；空串回退到「还在」。全工程只在这里做这一个判断。
    static func clean(_ s: String?) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    /// 现在叫什么。
    static var current: String {
        if let s = UserDefaults.standard.string(forKey: key),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clean(s)
        }
        return clean(SharedStore.load().catName)
    }

    /// 改名。**先写 standard（同步落盘），再刷快照。**
    ///
    /// ★ 两处都写是必须的，不是冗余：
    ///   · standard —— Siri / 主 App 立刻能读到
    ///   · 快照    —— 小组件、灵动岛、通知标题都是从那儿读的
    ///   只写一处就会出现「Siri 叫新名、通知还叫旧名」这种一半对一半不对的状态。
    static func set(_ n: String) {
        let t = clean(n)
        UserDefaults.standard.set(t, forKey: key)

        var s = SharedStore.load()
        s.catName = t
        s.lastSeen = Date()
        SharedStore.save(s)
    }

    /// 迁移：老版本的名字只存在 App Group 快照里，搬进 standard。
    ///
    /// ★ 幂等，App 每次启动调一次都行：standard 已经有值就直接返回，
    ///   不会拿旧的快照把新名字盖回去。
    /// ★ 这是「救存量」的那一步 —— 用户升级上来不用重新起一次名。
    static func migrateIfNeeded() {
        let cur = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard cur.isEmpty else { return }

        let old = (SharedStore.load().catName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, old != fallback else { return }
        UserDefaults.standard.set(old, forKey: key)
    }
}
