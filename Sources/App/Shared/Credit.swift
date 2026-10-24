import Foundation

// MARK: - 方案 D：算力回收 —— 它自己买礼物送给你（2026-10-24）
//
// ★ 规矩全写在服务器的 `credit.py` 顶上，改这里之前先看它。
//
//   用户买的是**算力**。它起了「买礼物」的念头时，把一部分算力付进商城 ⇒
//   **本质是把算力收回来**，平台拿这部分省下的成本去发货。
//
// ★★★ 他 2026-10-24 定的最后一条规矩，比钱更要紧：
//   > 「AI 提议这个我不希望有……礼物的话是有惊喜比较好。」
//
//   ⇒ **礼物不预告、不询问。** 这里没有任何「它想给你买个 X，可以吗？」的提示。
//     界面上只说「**它给你带了东西**」，**点开才知道是什么**。
//     人事前只授权一次（开关 + 每月额度），之后它自己决定。
//
// ★ 三道闸（服务器那边也会再卡一次，这里是第二道）：
//   ① 没开授权 ⇒ 不会买；② 超过本月额度 ⇒ 不会买；
//   ③ **保底算力永远不动** ⇒ 不会出现「它把算力花光了、你没法跟它说话」。
//
// ★ 单位：服务器上叫「点」，1 点 = 1 元面值的服务。
//   界面上写「算力」—— 写「点」会跟「点击」混，看不懂。

struct CreditGift: Decodable, Identifiable {
    let id: String
    let name: String
    let desc: String
    let note: String
    let status: String
    let cost: Int
    /// 你翻开过没有 —— 惊喜只有一次，翻过就不再当新礼物了
    let opened: Bool

    enum CodingKeys: String, CodingKey {
        case id = "号", name = "名", desc = "说", note = "留言"
        case status = "状态", cost = "点", opened = "揭晓"
    }
}

struct CreditAuth: Decodable {
    let on: Bool
    let quota: Int
    enum CodingKeys: String, CodingKey {
        case on = "开", quota = "每月额度"
    }
}

struct CreditInfo: Decodable {
    let ok: Bool
    let left: Int          // 还剩多少算力
    let keep: Int          // 其中保底（永远不动）
    let monthSpent: Int    // 这个月它花了多少
    let canSpend: Int      // 它还能花多少
    let auth: CreditAuth?
    let gifts: [CreditGift]

    enum CodingKeys: String, CodingKey {
        case ok, left = "剩", keep = "保底", monthSpent = "本月猫花"
        case canSpend = "还能花", auth = "授权", gifts = "礼物"
    }

    /// 还没翻开的 —— 界面上只说「它给你带了东西」，不写名字
    var unopened: [CreditGift] { gifts.filter { !$0.opened } }
}

enum Credit {
    private static let base = "https://still-ui-design.app.workbuddy.host"

    /// 问服务器：账上什么情况、它买了什么。取不到返回 nil（界面上就什么都不画）。
    static func load() async -> CreditInfo? {
        guard let url = URL(string: base + "/api/credit/view") else { return nil }
        var req = URLRequest(url: url)
        req.stillStamp()          // ★ 登录制：贴票
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = "{}".data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let info = try? JSONDecoder().decode(CreditInfo.self, from: data),
              info.ok else { return nil }
        return info
    }

    /// 翻开了 —— 告诉服务器一声，别每次进来都重新揭一次。
    static func opened(_ id: String) async {
        _ = await post("/api/credit/reveal", ["号": id])
    }

    /// 事前授权一次。额度 0 = 关掉。
    @discardableResult
    static func authorize(on: Bool, quota: Int) async -> Bool {
        await post("/api/credit/authorize", ["开": on, "每月额度": quota]) != nil
    }

    private static func post(_ path: String, _ body: [String: Any]) async -> Data? {
        guard let url = URL(string: base + path),
              let raw = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.stillStamp()
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = raw
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }
}
