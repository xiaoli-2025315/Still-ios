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

    /// 可用的脑子列表。
    /// ★★★ 2026-11-20 根治：内置两款写死在本地，点脑子永远弹得出来。
    ///   以前整条列表靠联网读服务器，联网/贴票/解析任一环断就报「没读到脑子列表」——
    ///   聊天用同样地址照样通，唯独这里不通，反复重装也修不好。内置的就固定两款，
    ///   不该靠网络去「读」它。这里直接内置，跟服务端 agent_store.py 的两款 id/名字对齐。
    ///   联网只作为「看服务器有没有新增自定义脑子」的锦上添花，失败也照用本地两款。
    static func list() async throws -> [Item] {
        let local = builtin
        // 用 Cfg.baseURL（本文件在 Shared，也会被 Widget 编译，不能用 ActLab）。
        var req = URLRequest(url: URL(string: Cfg.baseURL + "/api/agent/list")!)
        req.stillStamp()
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return local }
            let decoded = try JSONDecoder().decode(ListResp.self, from: data)
            if let remote = decoded.agents, !remote.isEmpty { return remote }
        } catch {
            return local   // 联网失败无所谓，本地内置两款照常给用户选
        }
        return local
    }

    /// 内置两款（与服务端 agent_store.py 完全对齐；不联网、永远在）。
    static var builtin: [Item] {
        [
            Item(id: "hermes", name: "会惦记你（默认）", intro: "会慢慢记住你的小事，聊着聊着就惦记上了。"),
            Item(id: "openfuse_gift", name: "会张罗、会送礼", intro: "更爱张罗事、说话更有劲，往后会主动给你送东西。"),
        ]
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
