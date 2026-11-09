import Foundation

/// ★★★ 2026-11-08：**做完那一刻，手机是被台子喊醒的，不是自己隔一阵去问。**
///
/// 他 11-07 的原话：「为什么要去问，你送到 APP 那一刻不就知道了」。
/// 以前 iOS 是装过一次就把旧包交回去，连重新点「用它」都不肯重下；
/// 台子上新做好的动作永远进不了手机。现在改成台子把「做完了」挂在这儿，
/// App 一连上就等着，做完立刻被喊一声 → 强制重下 → 装好 → 回一句
/// 「装好了」→ 台子才让「做好了」亮。不点「用它」、不进动作库、不切角色。
///
/// 两条路，同一份落盘事件：
///   · 长连接（stream=1）：台子有话说才说，做完立刻写下来（主路）。
///   · 挂着的等通知（wait）：网关把长连接掐了退到这条，仍是事件到了才回。
///
/// ★ 开机只准对账：首连那张单子只用来「把缺的补上」，不下任何判决。
/// ★ 补包失败一声不吭，下次重连 / 下次开机会再来。
/// ★ 只在 App 活着（前台）时挂着；后台 / 锁屏那一段靠下次连上补回来 ——
///   这是系统限制，不是漏做，别在界面上编「已送达」这类假话。
final class PackEvents: @unchecked Sendable {

    static let shared = PackEvents()

    private let lock = NSLock()
    private var started = false
    private var lastN: Int64 = 0
    private var sseFails = 0

    private struct Ev: Decodable {
        let n: Int64?
        let char: String?
        let stamp: Int64?
    }
    private struct Item: Decodable {
        let char: String?
        let stamp: Int64?
    }
    private struct Payload: Decodable {
        let seq: Int64?
        let events: [Ev]?
        let reconcile: [Item]?
        enum CodingKeys: String, CodingKey {
            case seq, events
            case reconcile = "对账"
        }
    }

    private init() { }

    func start() {
        lock.lock()
        let first = !started
        if first { started = true }
        lock.unlock()
        guard first else { return }
        Task.detached(priority: .background) { [weak self] in
            await self?.loop()
        }
    }

    private func loop() async {
        while true {
            do {
                if sseFails < 2 {
                    try await listen()          // 正常不会返回，返回＝连接断了
                    sseFails += 1
                } else {
                    try await poll()
                }
            } catch {
                sseFails += 1
            }
            let secs = sseFails >= 2 ? 3 : 1
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
        }
    }

    private func request(stream: Bool) -> URLRequest {
        var comp = URLComponents(string: ActLab.base + "/api/act/events")!
        comp.queryItems = stream
            ? [URLQueryItem(name: "stream", value: "1"),
               URLQueryItem(name: "since", value: String(lastN))]
            : [URLQueryItem(name: "since", value: String(lastN)),
               URLQueryItem(name: "wait", value: "25")]
        var req = URLRequest(url: comp.url!)
        // 长连接靠台子每 20 秒一次心跳；挂着的等通知最多 25 秒，给足余量
        req.timeoutInterval = stream ? 120 : 35
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        req.stillStamp()                     // ★ 登录制：贴票（只给台子贴）
        return req
    }

    /// 主路：一条挂着的连接，台子做完那一刻把事件写下来。
    private func listen() async throws {
        let (bytes, resp) = try await URLSession.shared.bytes(for: request(stream: true))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        var line: [UInt8] = []
        for try await b in bytes {
            if b == 10 {                      // \n
                let s = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                line.removeAll(keepingCapacity: true)
                if s.hasPrefix("data: ") {
                    await handle(String(s.dropFirst(6)))
                }
                // ": ping" 心跳、空行一律跳过
            } else {
                line.append(b)
            }
        }
    }

    /// 兜底：长连接被网关掐了，改成挂着的等通知（同样是事件到了才回）。
    private func poll() async throws {
        let (data, resp) = try await URLSession.shared.data(for: request(stream: false))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        await handle(String(decoding: data, as: UTF8.self))
        sseFails = 0                         // 通了就再试一次长连接
    }

    /// 一批事件：逐只补包 → 补好了回报台子 → 台子才让「做好了」亮。
    private func handle(_ json: String) async {
        guard let d = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: d) else { return }
        var done: Set<String> = []

        // ① 首连对账：只补「正在用的这只」，别一次把所有猫的几十 MB 全搬回来。
        if let _ = p.reconcile, lastN == 0 {
            let cur = await MainActor.run { CatPackStore.shared.current?.id }
            if let id = cur, !id.isEmpty {
                done.insert(id)
                await deliver(id)
            }
        }

        // ② 做完事件：事件点名哪只就补哪只，哪怕现在没在用。
        for e in p.events ?? [] {
            if let n = e.n, n > lastN { lastN = n }
            if let id = e.char, !id.isEmpty, !done.contains(id) {
                done.insert(id)
                await deliver(id)
            }
        }
        if let s = p.seq, s > lastN { lastN = s }
    }

    private func deliver(_ id: String) async {
        guard id != CatPackStore.builtinId else { return }   // 自带那只在包里，不用下
        do {
            let m = try await ActLab.manifest(charId: id)
            guard m.stamp > 0 else { return }
            let key = "still.packstamp." + id
            let local = Int64(UserDefaults.standard.integer(forKey: key))
            let has = await MainActor.run { CatPackStore.shared.isInstalled(id) }
            if local >= m.stamp && has {
                await ack(id: id, stamp: m.stamp)
                return
            }
            // ★ iOS 以前装过一次就直接把旧包交回去 —— 强制重下是这一步补上的。
            let pack = try await CatPackStore.shared.install(charId: id, force: true)
            await MainActor.run {
                // 正在用的这只装完要重挂一次，否则画面还拿旧包的索引
                if CatPackStore.shared.isCurrent(id) { CatPackStore.shared.use(pack) }
            }
            // ★★★ 2026-11-09：先回报、成了才记版本号。先记后报时，
            //   回报没送到 ⇒ 本机以为已是最新 ⇒ 台子永远收不到 installed ⇒
            //   状态永久卡在「正在送到手机」（SSE 这条路和制作页那条路同一个坑）。
            if await ack(id: id, stamp: m.stamp) {
                UserDefaults.standard.set(m.stamp, forKey: key)
            }
        } catch {
            // 不吭声，下次重连 / 下次开机再来
        }
    }

    /// 手机说：这版我已经装进本地了。台子收到才把「做好了」点亮。
    /// 返回「台子真的收下了没有」—— 没收下就不许把本地版本号记成最新。
    @discardableResult
    private func ack(id: String, stamp: Int64) async -> Bool {
        guard let url = URL(string: ActLab.base + "/api/act/installed") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.stillStamp()
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["char": id, "stamp": stamp])
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return false }
            let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            return (o?["ok"] as? Bool) ?? true
        } catch {
            return false
        }
    }
}
