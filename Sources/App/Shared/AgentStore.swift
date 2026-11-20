//  OTCO 第0步（2026-11-20）：每只角色单独选一个 Agent。
//  ★ 只加不改：新文件，不碰任何原有类；只新增 UserDefaults 键 still.agent.<角色id>，
//    不删不改用户原有任何一条设置。
//
//  职责：
//    1. 记/读「某只角色用哪个 Agent」（本地，按角色隔离）。
//    2. 拉台子的可用 Agent 列表、把选择存上台子（选了坏了要能退默认）。

import Foundation

enum AgentStore {
    private static let prefix = "still.agent."
    static let `default` = "hermes"

    /// 这只角色选的 Agent。没选过 → 默认（老角色、存量都不受影响）。
    static func of(_ id: String) -> String {
        if id.isEmpty { return `default` }
        return UserDefaults.standard.string(forKey: prefix + id) ?? `default`
    }

    /// 记住选择。传空或 "hermes" = 回默认。
    static func set(_ agentId: String, for id: String) {
        guard !id.isEmpty else { return }
        let t = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == `default` {
            UserDefaults.standard.removeObject(forKey: prefix + id)
        } else {
            UserDefaults.standard.set(t, forKey: prefix + id)
        }
    }

    struct Item: Decodable, Identifiable {
        let id: String
        let name: String
        let intro: String?
        var identifier: String { id }
    }

    private struct ListResp: Decodable {
        let ok: Bool?
        let agents: [Item]?
    }

    /// 拉台子可用的 Agent 列表。失败抛出，界面提示重试，绝不显示假数据。
    static func list() async throws -> [Item] {
        // ★ 用 Cfg.baseURL 不用 ActLab.base：本文件在 Shared 里，也会被 Widget target
        //   一起编译，而 Widget 不含 ActLab（主 App 专属），引用它会编译失败。
        var req = URLRequest(url: URL(string: Cfg.baseURL + "/api/agent/list")!)
        req.stillStamp()      // ★ 登录制：贴票，跟别的接口一样
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "agent", code: -1, userInfo: nil)
        }
        let decoded = try JSONDecoder().decode(ListResp.self, from: data)
        return decoded.agents ?? []
    }

    /// 把某只角色的选择存上台子（台子按 uid+角色隔离）。
    static func saveToCloud(_ agentId: String, for charId: String) async {
        let body = ["char": charId, "agentId": agentId]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: URL(string: Cfg.baseURL + "/api/agent/set")!)
        req.httpMethod = "POST"
        req.stillStamp()
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 20
        _ = try? await URLSession.shared.data(for: req)
    }
}
