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

    /// 问真 AI。**拿不到就返回 nil**（不是抛错）—— 调用方自己掉回本地那套。
    ///
    /// ★★★ 2026-10-23（他的原话）：「IOS 也要可以加 key 啊，他是用户可以自己接入 API
    ///   给每个角色的」。原来是「钥匙插在台子上」—— 用户想用自己的模型，
    ///   只能在服务器上改，手机上根本没地方填。现在两条路：
    ///
    ///   ① **这只猫自己有一把钥匙** → 直连模型（智谱 / DeepSeek，跟安卓同两家同型号）；
    ///   ② 没填，或者直连失败 → 走台子 `/api/cat/chat`（台子上插着的那把）。
    ///
    ///   ★ 为什么②不能砍：台子那条是「装完就能说话」的默认值。
    ///     砍了以后，没填钥匙的人打开就是一只只会喵的猫，比现在更差。
    ///   ★ 为什么①失败要静默掉回②、而不是报错：一句（蹭了蹭你）也比什么都不说好。
    static func replyFromCloud(to message: String, catName: String) async -> String? {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return nil }

        // ① 这只猫自己的钥匙
        let k = key(for: currentCharId)
        if !k.isEmpty, let r = await askModel(m, key: k, catName: catName) {
            return r
        }

        // ② 台子
        return await askStage(m)
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
        if k.isEmpty { return "台子上那把（不用填也能说话）" }
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

    /// 走台子那条（原来的路，钥匙在服务器上）。
    private static func askStage(_ m: String) async -> String? {
        let payload: [String: Any] = ["msg": m, "history": []]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var req = URLRequest(url: cloudURL)
        req.stillStamp()      // ★ 登录制：贴票
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = cloudTimeout
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            // 不是 2xx 就当没问到 —— 台子 500 / 网关拦了 / 钥匙没插，都走这条路。
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["ok"] as? Bool == true,
                  let text = json["reply"] as? String else { return nil }
            let r = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.isEmpty ? nil : r
        } catch {
            // 断网 / 超时 / 证书问题，一律当「这次没问到」，不惊动任何人。
            return nil
        }
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
