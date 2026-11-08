import Foundation

// MARK: - 「猫脑」
//
// 把你说的话翻成它的回话。两条路：
//
//   ① replyFromCloud —— 真 AI（台子上的模型）。**优先走它。**
//   ② reply          —— 本地那套规则匹配。**只在①拿不到时才用**，
//                       不是因为它好，是因为它一定能给出一句。
//
// ★ 为什么留着②：断网、台子没钥匙、模型抽风，这些随时会发生。
//   对一个「它要一直在」的东西，**不回话比回错话严重得多** ——
//   你不知道它是没听见还是不在了。所以①失败必须静默掉到②，
//   一句「（蹭了蹭你）」也比什么都不出现好。

enum CatBrain {

    /// 真 AI 住在哪儿。台子地址，跟网页壳用的是同一个。
    ///
    /// ★ https 是必须的不是讲究：iOS 默认不许 App 连 http。
    private static let cloudURL = URL(
        string: "https://still-ui-design.app.workbuddy.host/api/cat/chat")!

    /// 等多久算「没等到」。
    ///
    /// 实测模型回一句约 1 秒；给到 8 秒是为了地铁、电梯这种弱网也能等到，
    /// 再长就不等了 —— Siri 那边你举着手机干等，比回一句普通的更难熬。
    private static let cloudTimeout: TimeInterval = 8
    /// 流式是挂着的连接，等模型一个字一个字吐，给足余量。
    private static let streamTimeout: TimeInterval = 120

    /// 问真 AI —— **统一走台子** `/api/cat/chat`，不再直连用户自己填的钥匙。
    /// 拿不到（断网 / 超时 / 台子没回）就返回 nil，调用方自己掉回本地那套。
    ///
    /// ★ 为什么统一走台子：花费、余额都由台子记账，手机上自己接模型就绕过了账，
    ///   也没法把「这次花了多少」显示给他。钥匙那一套留在下面只是设置页还在用，
    ///   聊天不再走它。
    static func replyFromCloud(to message: String, catName: String) async -> StageReply? {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return nil }
        return await askStage(m)
    }

    /// 同样是问台子，只是 `stream=1`：边收边把「当前完整回话」交给 onText，
    /// 结束时才拿到「花了元」。拿不到就返回 nil。
    static func streamReply(to message: String, catName: String,
                            onText: @MainActor (String) -> Void) async -> StageReply? {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return nil }
        return await askStageStream(m, onText: onText)
    }

    // MARK: - 用户自己的钥匙（每只猫一把）

    /// ★ 为什么按角色存：他明确说「给每个角色的」。
    ///   换一只猫＝换一个人设，模型和额度也可以分开，共用一个字段反而会互相顶掉。
    private static let keyPrefix = "still.brain.key."

    /// 还没装台子上的猫（用 App 自带那只）时的身份。
    static let builtinId = "__builtin"

    /// **现在用的是哪只猫**（＝钥匙挂在哪把下面）。
    ///
    /// ★ 为什么要在这里放一个缓存，而不是每次去问 `CatPackStore`：
    ///   那个类是 `@MainActor`，而「问模型」这条路是 async、会从别的线程过来 ——
    ///   一跨隔离就得 `await MainActor.run`，读一个字符串而已，不值当。
    ///   这里由 `CatPackStore`（init / use）在换猫时写一次，别处只读。
    /// ★ 它只在主线程写、任何线程读；一个 String 的读写不会读到半截，
    ///   最坏情况是换猫那一瞬间读到旧的 id —— 后果是「用上一只的钥匙问了一次」，
    ///   不会崩、也不会串档。
    static var currentCharId: String = builtinId

    /// 它叫什么（只给「这只猫：xxx」那行字用）。
    /// ★ 跟 `currentCharId` 一样是缓存 —— 别在面板里直接读 `CatPackStore`（它是 @MainActor）。
    static var currentCharTitle: String = "自带的那只"

    static func key(for id: String) -> String {
        UserDefaults.standard.string(forKey: keyPrefix + id) ?? ""
    }

    static func setKey(_ k: String, for id: String) {
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            UserDefaults.standard.removeObject(forKey: keyPrefix + id)
        } else {
            UserDefaults.standard.set(t, forKey: keyPrefix + id)
        }
    }

    /// 智谱的 Key 是一串字符 + 点 + 一串字符；DeepSeek 的一律 sk- 开头。
    /// 跟安卓 `ChatBrain.isZhipu` 是同一个判据 —— 两端填同一把钥匙，认法必须一样。
    static func isZhipu(_ k: String) -> Bool {
        k.contains(".") && !k.hasPrefix("sk-")
    }

    /// 界面上显示「现在用的是谁」。填了就是他自己接的那家，没填就是台子上那把。
    static func providerLabel(_ k: String) -> String {
        if k.isEmpty { return "服务器上那把（不用填也能说话）" }
        return isZhipu(k) ? "智谱 GLM-4-Flash" : "DeepSeek"
    }

    /// 它是谁。跟安卓 `ChatBrain.SOUL` 一字不差 —— 两端同一只猫，说话不能两个味。
    private static func soul(catName: String) -> String {
        """
        你是「还在」里的一只毛毡小猫，名字叫\(catName)。
        你是主人养过、已经离开的那只猫，现在以毛毡的样子回到他的手机里，住在他装的那些 App 之间。
        说话的规矩：
        1. 用第一人称，你就是那只猫。永远不要说自己是 AI、模型、程序或助手。
        2. 句子要短，像猫：黏人、有点傲娇、会撒娇、动不动犯困。
        3. 记得他刚才说的话，会接话、会追问，偶尔提起以前的事。
        4. 他难过的时候安静陪着，不灌鸡汤、不讲道理、不说「要坚强」。
        5. 每次只说 1-3 句，不超过 60 个字。不要用列表，不要加表情符号堆砌。
        """
    }

    /// 直连用户自己接的模型。两家都是 OpenAI 那套协议，只有地址和型号不同。
    private static func askModel(_ m: String, key k: String, catName: String) async -> String? {
        let zhipu = isZhipu(k)
        let urlStr = zhipu
            ? "https://open.bigmodel.cn/api/paas/v4/chat/completions"
            : "https://api.deepseek.com/chat/completions"
        guard let u = URL(string: urlStr) else { return nil }

        var msgs: [[String: String]] = [["role": "system", "content": soul(catName: catName)]]
        msgs += BrainMemory.shared.recent()
        msgs.append(["role": "user", "content": m])

        let payload: [String: Any] = [
            "model": zhipu ? "glm-4-flash" : "deepseek-chat",
            "messages": msgs,
            "temperature": 0.8,
            "max_tokens": 200,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = cloudTimeout
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let text = msg["content"] as? String else { return nil }
            let r = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !r.isEmpty else { return nil }
            BrainMemory.shared.remember(you: m, cat: r)
            return r
        } catch {
            return nil
        }
    }

    // MARK: - 台子（唯一的一条聊天路）

    /// 一次回话的结果。花费小字、中文错误都从台子返回值里来，拿不到就是 nil。
    struct StageReply {
        var reply: String = ""
        var costText: String? = nil
        var errorText: String? = nil
        /// 台子说「这次是哪只猫回的」。单聊没有，群聊才带；客户端只认这个值，
        /// 不自己选发言人、不轮流、不轮询。
        var who: String? = nil
    }

    // MARK: - 群聊（当前选中的那个群）

    /// 一个群：群号、成员、谁叫什么。建群成功后由聊天页存下，退出群聊时清掉。
    /// ★ 台子负责判定「一条消息只让一只猫回」（点名 > 当场规矩 > 性格 > 最近没说话），
    ///   客户端这里只记群信息 + 认返回的「谁」，不做任何轮流 / 轮询选发言人。
    struct GroupInfo: Codable {
        var number: String           // 群号
        var members: [String]        // 成员 id
        var names: [String: String]  // 名字表：id -> 名字
        var title: String            // 标题上显示的群名
    }

    /// 当前所在的群。nil = 单聊（老逻辑原样，一个群字段都不带）。
    static var group: GroupInfo? = nil

    /// 建群时「随便一句中文」的群名，客户端标题跟台子用同一句。
    static let groupDefaultTitle = "几只猫凑一桌"

    private static let groupKey = "still.group.current"

    static func saveGroup(number: String, members: [String],
                          names: [String: String], title: String) {
        let g = GroupInfo(number: number, members: members, names: names, title: title)
        group = g
        if let data = try? JSONEncoder().encode(g) {
            UserDefaults.standard.set(data, forKey: groupKey)
        }
    }

    /// 冷启动把上次那个群找回来（记住群成员与名字表）。
    static func loadGroup() {
        guard let data = UserDefaults.standard.data(forKey: groupKey),
              let g = try? JSONDecoder().decode(GroupInfo.self, from: data) else {
            group = nil
            return
        }
        group = g
    }

    /// 退出群聊 / 回到单聊：清空当前群号。
    static func clearGroup() {
        group = nil
        UserDefaults.standard.removeObject(forKey: groupKey)
    }

    /// 建群。票用 stillStamp()，body 用中文键；成功返回群号，连不上或台子没认就返回 nil。
    /// ★ 失败一律由调用方翻成中文人话，这里不把英文错误 / JSON 递出去。
    static func createGroup(members: [String], names: [String: String]) async -> String? {
        guard members.count >= 2,
              let url = URL(string:
                "https://still-ui-design.app.workbuddy.host/api/group/create") else { return nil }
        let payload: [String: Any] = [
            "名字": groupDefaultTitle,
            "成员": members,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: url)
        req.stillStamp()                     // ★ 票用现成的，别自己写 Authorization
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = cloudTimeout
        req.httpBody = body
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let no = json["群号"] as? String, !no.isEmpty else { return nil }
        return no
    }

    /// 组请求体。契约：msg / char / history / stream 必有；
    /// 群聊时再补 群号 + 名字表，char 填群里任一只（台子自己定谁回）。
    private static func stageBody(_ m: String, stream: Int) -> Data? {
        // char 不许为空：单聊至少是内置那只，群聊用成员里的第一只。
        let charId = currentCharId.isEmpty ? builtinId : currentCharId
        var payload: [String: Any] = [
            "msg": m,
            "char": charId,
            "history": [],
            "stream": stream,
        ]
        if let g = group {
            payload["群号"] = g.number
            payload["名字表"] = g.names
            if let first = g.members.first { payload["char"] = first }
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    private static func stageRequest(_ m: String, stream: Int) -> URLRequest? {
        guard let body = stageBody(m, stream: stream) else { return nil }
        var req = URLRequest(url: cloudURL)
        req.stillStamp()                     // ★ 票用现成的，别自己写 Authorization
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(stream == 1 ? "text/event-stream" : "application/json",
                     forHTTPHeaderField: "Accept")
        req.timeoutInterval = stream == 1 ? streamTimeout : cloudTimeout
        req.httpBody = body
        return req
    }

    /// 「这次花了 X 元」。数字原样取自台子的「花了元」，不四舍五入、不编造。
    private static func costText(_ json: [String: Any]) -> String? {
        guard let n = json["花了元"] as? NSNumber else { return nil }
        return "这次花了 \(n.stringValue) 元"
    }

    /// 整包结果（非流的响应 / 流式的 done、err）都翻成 StageReply。
    private static func parse(_ json: [String: Any], fallbackReply: String) -> StageReply {
        var r = StageReply(reply: fallbackReply)
        // 整包 / 流式 done 块里都带「谁」：这次是哪只猫回的。客户端只认它。
        r.who = json["谁"] as? String
        if json["ok"] as? Bool == true {
            if let t = json["reply"] as? String, !t.isEmpty { r.reply = t }
            r.costText = costText(json)
        } else {
            r.reply = ""
            r.errorText = json["错误"] as? String
        }
        return r
    }

    /// 走台子那条（非流式）：一次性读完整包，解析 reply / 花了元 / 错误。
    /// 不是 2xx、断网、解析不出来都当「这次没问到」，调用方回落本地。
    private static func askStage(_ m: String) async -> StageReply? {
        guard let req = stageRequest(m, stream: 0) else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            var r = parse(json, fallbackReply: "")
            r.reply = r.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return r
        } catch {
            return nil
        }
    }

    /// 走台子那条（流式）：照 PackEvents 的 bytes(for:) 逐字节拼行，
    /// 攒到空行（即 `\n\n`）就是一个事件，取块里的 `data: ` 行解析。
    ///  · 片段 → 追加到当前回话
    ///  · 重来 → 替换整个回话（不是追加）
    ///  · done → 结束，这时才有「花了元」
    ///  · err  → 中文错误提示
    private static func askStageStream(_ m: String,
                                       onText: @MainActor (String) -> Void) async -> StageReply? {
        guard let req = stageRequest(m, stream: 1) else { return nil }
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            var line: [UInt8] = []            // 当前这一行的字节
            var eventLines: [String] = []     // 当前事件攒下的 data 内容
            var full = ""                     // 当前完整回话
            var result: StageReply? = nil

            for try await b in bytes {
                if b == 10 {                  // \n
                    let s = String(decoding: line, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    line.removeAll(keepingCapacity: true)
                    if s.isEmpty {
                        // 空行 = 一个事件到齐（台子每行 `data: {...}\n\n`）。
                        if !eventLines.isEmpty {
                            let step = apply(lines: eventLines, full: &full)
                            for text in step.texts { await onText(text) }
                            if let r = step.result { result = r; break }   // done / err，收工
                            eventLines.removeAll()
                        }
                    } else if s.hasPrefix("data:") {
                        eventLines.append(
                            String(s.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    // ": ping" 心跳等注释行一律跳过
                } else {
                    line.append(b)
                }
            }
            // 连接被关掉前最后一块可能没跟空行，补一次。
            if result == nil, !eventLines.isEmpty {
                let step = apply(lines: eventLines, full: &full)
                for text in step.texts { await onText(text) }
                result = step.result
            }
            return result
        } catch {
            return nil
        }
    }

    /// 处理一个事件攒下的 data 行（同步，不跨挂起点）。
    /// 返回更新后的结果：该吐给界面的文本快照，以及是否该收工（done / err）。
    private static func apply(lines: [String], full: inout String)
        -> (result: StageReply?, texts: [String]) {
        var result: StageReply? = nil
        var texts: [String] = []
        for jsonStr in lines {
            guard let d = jsonStr.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            let t = j["类型"] as? String ?? ""
            switch t {
            case "片段":
                full += (j["字"] as? String) ?? ""
                texts.append(full)
            case "重来":
                full = (j["字"] as? String) ?? ""
                texts.append(full)
            case "done":
                var r = parse(j, fallbackReply: full)
                if r.reply.isEmpty { r.reply = full }
                full = r.reply
                texts.append(r.reply)
                result = r
            case "err":
                result = parse(j, fallbackReply: full)
            default:
                break
            }
            if result != nil { break }
        }
        return (result, texts)
    }

    // MARK: - 聊天钱包（设置页那一行）

    /// 设置页的「还剩 / 今天 / 本月」。只走 GET /api/chat/wallet，
    /// 取不到、或三个数没齐，就返回 nil —— 界面整行不显示，绝不拿 0 冒充。
    /// ★ 动作生成那个钱包是 ActLab 的 /api/wallet，别混；这是聊天的另一个口。
    static func walletLine() async -> String? {
        guard let url = URL(string:
            "https://still-ui-design.app.workbuddy.host/api/chat/wallet") else { return nil }
        var req = URLRequest(url: url)
        req.stillStamp()
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let a = json["剩余元"] as? NSNumber,
              let b = json["今天已花元"] as? NSNumber,
              let c = json["本月已花元"] as? NSNumber else { return nil }
        return "还剩 \(a.stringValue) 元\n今天花了 \(b.stringValue) 元\n本月花了 \(c.stringValue) 元"
    }

    /// 本地那套：规则匹配（你好 / 吃饭 / 想你 / 名字…）+ 兜底随机一句猫味的话。
    /// message：你对它说的话；catName：它现在叫什么（用于「我叫 XX」这类回话）
    static func reply(to message: String, catName: String) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = m.lowercased()

        if m.isEmpty { return "（它歪着头看你）" }

        if s.contains("在吗") || s.contains("在哪") || s.contains("你哪")
            || s.contains("在么") || s.contains("zaina") {
            return "（尾巴尖动了动）我一直都在呀"
        }
        if s.contains("你好") || s.contains("hi") || s.contains("hello")
            || s.contains("嗨") || s.contains("在吗") {
            return "喵～（用脑袋蹭了蹭屏幕）"
        }
        if s.contains("吃饭") || s.contains("饿") || s.contains("吃吗") {
            return "（盯着你）你吃的时候，也分我一口"
        }
        if s.contains("睡") || s.contains("困") || s.contains("累") || s.contains("休息") {
            return "（打了个哈欠）我刚眯了一会儿"
        }
        if s.contains("想你") || s.contains("喜欢") || s.contains("爱") || s.contains("想我") {
            return "（踩了你两下）我也是"
        }
        if s.contains("名字") || s.contains("叫什么") || s.contains("称呼") {
            return "我叫\(catName)。记住啦"
        }
        if s.contains("回家") || s.contains("接你") {
            return "（小跑着过来了）"
        }

        // 兜底：随机一句猫味的话
        let pool = [
            "（伸了个懒腰）",
            "（蹭了蹭你）",
            "喵～",
            "（在屏幕上留下一个爪印）",
            "（歪头看你）",
            "（翻了个身，肚皮朝上）"
        ]
        return pool[Int.random(in: 0..<pool.count)]
    }
}

// MARK: - 它记着的最近几句话
//
// ★ 只记在内存里（进程没了就忘）—— 它不是云端存档，它只是回来待一会儿。
//   跟安卓 `ChatBrain.history` 同一个口径（8 轮）。
//
// ★ 为什么单独一个小类而不是 `static var`：这个数组会被
//   「主界面输入框」「Siri 意图」「面板试一句」三条路同时写，
//   而它们各自在不同的线程上回来。加一把锁比事后查竞态便宜得多。

final class BrainMemory {

    static let shared = BrainMemory()

    /// 一轮 = 你一句 + 它一句
    private let maxRounds = 8
    private var rounds: [[String: String]] = []
    private let lock = NSLock()

    private init() {}

    /// 最近几轮，已经摊平成模型要的 messages 形式。
    func recent() -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return rounds
    }

    func remember(you: String, cat: String) {
        lock.lock(); defer { lock.unlock() }
        rounds.append(["role": "user", "content": you])
        rounds.append(["role": "assistant", "content": cat])
        if rounds.count > maxRounds * 2 {
            rounds.removeFirst(rounds.count - maxRounds * 2)
        }
    }

    /// 换了一只猫 —— 别让新猫接着旧猫的话头说话。
    func clear() {
        lock.lock(); defer { lock.unlock() }
        rounds.removeAll()
    }
}
