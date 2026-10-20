import Foundation

// MARK: - 台子上的「动作库」
//
// 这是安卓 `Act.java` 的 iOS 版，只搬两条读、一条写：
//   GET  /api/act/chars                     角色表：每只 + 它这套动作好了几条
//   GET  /api/act/manifest?char=<角色id>     这只的动作清单（一行一条，竖线分隔）
//   POST /api/act/char?name=&channel=&ext=   登记新角色（body 直接就是那张照片）
//
// ★ 上传是**裸 body**，不是 multipart —— 安卓那边 `postFile` 就是直接写字节。
//   所以这里用 `upload(for:from:)`，别包成表单，台子不认。
//
// ★ 「通道」两个值跟安卓一样：free（自己传动作视频，台子免费抠像）
//   / paid（台子按照片生成整套动作）。

enum ActLab {

    static let base = "https://still-ui-design.app.workbuddy.host"

    /// 台子原来就有的 12 条。跟安卓 `Act.OFFICIAL` 同一批、同一顺序 ——
    /// 两边对不上，用户看到的「好了 7 条」就不是同一件事。
    static let official: [(key: String, label: String)] = [
        ("sit", "坐着张望"), ("walk", "走路"), ("groom", "舔毛"), ("sleep", "睡着了"),
        ("liedown", "趴下"), ("wake", "起身"), ("walk_r", "行走·往右"),
        ("hunt1", "扑猎 1"), ("hunt2", "扑猎 2"), ("struggle", "挣扎"),
        ("inhale", "吸气"), ("exhale", "呼气"),
    ]

    // MARK: - 模型

    struct Char: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let channel: String?
        let img: String?
        let done: Int?

        var title: String { name.isEmpty ? id : name }
        var doneCount: Int { done ?? 0 }
        var isPaid: Bool { (channel ?? "free") == "paid" }
        var imgURL: URL? {
            guard let img, !img.isEmpty else { return nil }
            if img.hasPrefix("http") { return URL(string: img) }
            return URL(string: base + "/" + img.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
    }

    /// 某只的动作清单。只关心「有哪些名字」——够了，格子亮不亮就看这个。
    struct Manifest {
        var stamp: Int64 = 0
        /// 已经抠好、能下的动作名
        var names: Set<String> = []
        /// 还在队列里、没认领的（服务器起的 x_ 临时名）
        var pending: Int = 0
    }

    // MARK: - 响应壳

    private struct CharsResp: Decodable { let chars: [Char]? }

    private struct ManifestResp: Decodable {
        let stamp: Int64?
        let list: [String]?
        enum CodingKeys: String, CodingKey {
            case stamp
            case list = "清单"
        }
    }

    private struct NewResp: Decodable {
        let ok: Bool?
        let char: Char?
        let why: String?
        enum CodingKeys: String, CodingKey {
            case ok, char
            case why = "错误"
        }
    }

    // MARK: - 读

    static func chars() async throws -> [Char] {
        let r: CharsResp = try await get("/api/act/chars")
        return r.chars ?? []
    }

    static func manifest(charId: String) async throws -> Manifest {
        var comp = URLComponents(string: base + "/api/act/manifest")!
        comp.queryItems = [URLQueryItem(name: "char", value: charId)]
        let r: ManifestResp = try await get(absURL: comp.url!)

        var m = Manifest()
        m.stamp = r.stamp ?? 0
        for line in r.list ?? [] {
            // 一行长这样：name|显示名|帧数|…|fps
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard let head = parts.first else { continue }
            let nm = String(head)
            if nm.hasPrefix("x_") { m.pending += 1 } else if !nm.isEmpty { m.names.insert(nm) }
        }
        return m
    }

    // MARK: - 写：登记一个新角色

    /// - Parameters:
    ///   - photo: 已经转成 JPEG 的字节（相册里可能是 HEIC，台子不一定认）
    static func create(name: String, channel: String, photo: Data) async throws -> Char {
        var comp = URLComponents(string: base + "/api/act/char")!
        comp.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "ext", value: "jpg"),
        ]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: photo)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到台子的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw LabError("台子说 HTTP \(http.statusCode)：\(snip(data))")
        }
        let r = try? JSONDecoder().decode(NewResp.self, from: data)
        if let r, r.ok == false {
            throw LabError(r.why?.isEmpty == false ? r.why! : "登记失败")
        }
        if let c = r?.char { return c }
        // 台子回了 ok 但没给 char：拿名字现拼一只，界面至少能显示出来
        return Char(id: "", name: name, channel: channel, img: nil, done: 0)
    }

    // MARK: - 底层

    struct LabError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private static func get<T: Decodable>(_ path: String) async throws -> T {
        try await get(absURL: URL(string: base + path)!)
    }

    private static func get<T: Decodable>(absURL: URL) async throws -> T {
        var req = URLRequest(url: absURL)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LabError("没接到台子的回话") }
        guard (200..<300).contains(http.statusCode) else {
            throw LabError("台子说 HTTP \(http.statusCode)：\(snip(data))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func snip(_ d: Data) -> String {
        let s = String(data: d.prefix(160), encoding: .utf8) ?? ""
        return s.isEmpty ? "（没有正文）" : s
    }
}
