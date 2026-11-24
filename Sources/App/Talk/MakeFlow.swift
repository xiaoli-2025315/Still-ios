import Foundation

// MARK: - 聊天内做动态形象的状态机（2026-11-24，与安卓 做形象流程.java 对称）
//
// 上传白底图 → 确认 → 选方式（模型/豆包）→ 制作中（不给假百分比）→ 完成。
// 状态落 UserDefaults，切走/关 App 再回来接着走。这一层不碰网络、不碰钱；
// 下单/上传/查进度都在 TalkPage 里调 ActLab 的现成封装。

enum MakeFlow {
    static let S_WAIT_IMG = "wait_img"
    static let S_CONFIRM = "confirm"
    static let S_WAY = "way"
    static let S_DOUBAO_BIND = "doubao_bind"
    static let S_MAKING = "making"
    static let S_DONE = "done"

    static let WAY_MODEL = "模型"
    static let WAY_DOUBAO = "豆包"

    struct F {
        let charId: String
        var stage: String
        var way: String
    }

    private static func 键(_ id: String) -> String { "mk_" + id }

    static func 开始(_ id: String) { 写(id, S_WAIT_IMG, "") }

    static func 读(_ id: String) -> F? {
        guard let d = UserDefaults.standard.dictionary(forKey: 键(id)),
              let st = d["stage"] as? String, !st.isEmpty, st != S_DONE else { return nil }
        return F(charId: id, stage: st, way: d["way"] as? String ?? "")
    }

    private static func 写(_ id: String, _ stage: String, _ way: String) {
        UserDefaults.standard.set(["stage": stage, "way": way, "at": Date().timeIntervalSince1970],
                                  forKey: 键(id))
    }

    static func 到确认(_ f: inout F) { f.stage = S_CONFIRM; 写(f.charId, S_CONFIRM, f.way) }
    static func 到选方式(_ f: inout F) { f.stage = S_WAY; 写(f.charId, S_WAY, f.way) }
    static func 到绑豆包(_ f: inout F) { f.stage = S_DOUBAO_BIND; f.way = WAY_DOUBAO; 写(f.charId, S_DOUBAO_BIND, WAY_DOUBAO) }
    static func 到制作中(_ f: inout F, _ 选: String) { f.stage = S_MAKING; f.way = 选; 写(f.charId, S_MAKING, 选) }
    static func 到完成(_ f: inout F) { f.stage = S_DONE; 写(f.charId, S_DONE, f.way) }
    static func 取消(_ f: inout F) { f.stage = S_DONE; 写(f.charId, S_DONE, f.way) }

    /// 确认阶段：1=就用这张 0=重传 -1=没到这步
    static func 确认回答(_ f: F, _ 话: String) -> Int {
        guard f.stage == S_CONFIRM else { return -1 }
        if 话.contains("重") || 话.contains("换") || 话.contains("不要") { return 0 }
        return 1
    }

    /// 选方式阶段："模型"/"豆包"/nil
    static func 方式回答(_ f: F, _ 话: String) -> String? {
        guard f.stage == S_WAY else { return nil }
        if 话.contains("豆包") || 话.contains("免费") { return WAY_DOUBAO }
        if 话.contains("模型") || 话.contains("wan") || 话.contains("花") { return WAY_MODEL }
        return nil
    }

    /// 绑豆包回来
    static func 绑好回来(_ f: F, _ 话: String) -> Bool {
        guard f.stage == S_DOUBAO_BIND else { return false }
        return 话.contains("好") || 话.contains("绑") || 话.contains("回来") || 话.contains("重") || 话.contains("选")
    }

    /// 等图阶段取消
    static func 等图取消(_ f: F, _ 话: String) -> Bool {
        guard f.stage == S_WAIT_IMG else { return false }
        return 话.contains("不做") || 话.contains("取消") || 话.contains("算了")
    }
}
