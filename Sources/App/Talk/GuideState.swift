import Foundation

// MARK: - 新角色聊天内引导（2026-11-24）
//
// 它主动问名字 → 人设 → 要不要动态形象。状态落 UserDefaults，
// 切走页面、关 App 再回来都能接着走。文案是产品原文，一字不改。

enum GuideState {
    static let STEP_NAME = "name"
    static let STEP_PERSONA = "persona"
    static let STEP_IMAGE = "image"
    static let STEP_DONE = "done"

    private static let key = "still.guide"

    struct G {
        let charId: String
        var step: String
        var 方式: String
    }

    private static func 键(_ id: String) -> String { "g_" + id }

    static func 开始(_ id: String, 方式: String) {
        写(id, STEP_NAME, 方式)
    }

    static func 读(_ id: String) -> G? {
        guard let d = UserDefaults.standard.dictionary(forKey: 键(id)),
              let st = d["step"] as? String, !st.isEmpty, st != STEP_DONE else { return nil }
        return G(charId: id, step: st, 方式: d["方式"] as? String ?? "模型")
    }

    private static func 写(_ id: String, _ step: String, _ 方式: String) {
        UserDefaults.standard.set(["step": step, "方式": 方式, "at": Date().timeIntervalSince1970],
                                  forKey: 键(id))
    }

    /// 用户在引导里回一句 → 推进到下一步，返回它该说的下一句（空 = 交回正常 chat）。
    @discardableResult
    static func 推进(_ g: inout G, _ 用户话: String) -> String {
        if g.step == STEP_NAME {
            let 名 = 提取名字(用户话)
            if !名.isEmpty {
                PetName.set(名)
                // ★ 2026-11-26：名字同步到台子 —— local_ 新角色当场登记（侧栏/记忆球才
                //   看得到），老角色改名字。失败不拦引导（本地名字已经落了）。
                let cid = g.charId
                let nm = 名
                Task { try? await ActLab.charName(charId: cid, name: nm) }
            }
            写(g.charId, STEP_PERSONA, g.方式); g.step = STEP_PERSONA
            return "好呀\(名)，那我就叫你阿明啦～以后就这么喊你"
        } else if g.step == STEP_PERSONA {
            UserDefaults.standard.set(用户话, forKey: "人设_" + g.charId)
            写(g.charId, STEP_IMAGE, g.方式); g.step = STEP_IMAGE
            return "记下啦，我会照着这个样子陪你说话"
        }
        return ""
    }

    /// 形象那步的回答：1=现在就做 0=以后再说 -1=还没到这步
    static func 处理形象(_ g: inout G, _ 用户话: String) -> Int {
        guard g.step == STEP_IMAGE else { return -1 }
        let 做 = 用户话.contains("做") || 用户话.contains("现在") || 用户话.contains("好") || 用户话.contains("要")
        写(g.charId, STEP_DONE, g.方式); g.step = STEP_DONE
        return 做 ? 1 : 0
    }

    static func 问句(_ step: String) -> String {
        switch step {
        case STEP_NAME: return "你好呀～我们认识一下吧。你想给我起个什么名字？又该怎么称呼你呢？"
        case STEP_PERSONA: return "那，你希望我是什么样子的？性格呀、说话的方式呀，随便说～"
        case STEP_IMAGE: return "对了，想不想让我有个能看见的样子？现在就能给你做一个会动的形象～"
        default: return ""
        }
    }

    private static func 提取名字(_ s: String) -> String {
        if let at = s.firstIndex(of: "叫") {
            let 后 = String(s[s.index(after: at)...])
            let 名 = 后.components(separatedBy: CharacterSet(charactersIn: "，,。！!？? ")).first ?? ""
            if !名.isEmpty && 名.count <= 12 { return 名 }
        }
        return s.count > 8 ? String(s.prefix(8)) : s
    }
}
