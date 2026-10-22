import Foundation
import Security

// MARK: - 账号（登录制）
//
// ★★★ 2026-10-22 他定的（原话）：
//   「我需要让这个 APP 变成登录制的，现在就像是所有的用户共用一个 APP 一样，
//     我要所有的用户就像 QQ 啊豆包他们可以自己登录自己的账号。」
//
//   在这之前：台子里**一行用户代码都没有** —— 所有人共用一份角色表、一份进度、
//   一条生成道、一个豆包号。谁做了新角色，别人也能看见、也能删。
//
//   这里做的是最底下那一层：手机号 + 密码 → 一张票。
//   · 票存在**钥匙串**里（不是 UserDefaults）—— 它是凭证，不该躺在明文配置里。
//   · 票有效期 90 天，过期后台子会回 401，App 就退回登录页。
//   · 密码只往台子送一次，App 这边**一个字都不存**。

/// 票的读写。单独拎出来是因为有很多地方要同步读它（拼请求头），
/// 不能等 `@MainActor` 上的对象。
enum Ticket {
    private static let key = "still.ticket"

    static var current: String {
        Keychain.get(key) ?? ""
    }

    static func save(_ t: String) {
        Keychain.set(t, key)
    }

    static func clear() {
        Keychain.del(key)
    }
}

/// 给请求贴票 —— 一行，所有走台子的请求都要过它。
extension URLRequest {
    mutating func stillStamp() {
        let t = Ticket.current
        guard !t.isEmpty else { return }
        // ★ 只给台子贴，别把票发给别人 —— 第三方地址一律不贴。
        guard let h = url?.host, h.contains("workbuddy.host") else { return }
        setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
    }
}

/// 最小的钥匙串封装：只存一个字符串。
enum Keychain {
    static func set(_ value: String, _ key: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.still.app",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.still.app",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func del(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.still.app",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - 登录态

/// ★ 这个类**故意不加 `@MainActor`**：SwiftUI 的 View 属性默认值在非隔离的 init 里跑，
///   加了以后 `StillAuth.shared` 在属性声明那儿会报「跨隔离」。改成「类不隔离、
///   改状态的方法各自进主线程」—— 一样安全，而且各处引用都不会打架。
final class StillAuth: ObservableObject {
    static let shared = StillAuth()

    struct Me: Codable, Equatable {
        var uid: String
        var phone: String
        var name: String
        var owner: Bool
    }

    /// 有没有登录。App 的入口看这一个。
    @Published private(set) var signedIn = false
    /// 我在台子上是谁（登录后才有）。
    @Published private(set) var me: Me?
    /// 正在跟台子说话 —— 按钮转圈用。
    @Published private(set) var busy = false
    /// 台子回的那句人话（登录失败、号码不对……）。
    @Published var error = ""

    private let base = "https://still-ui-design.app.workbuddy.host"
    /// 昵称这些不是凭证，放本地就够了，免得每次进来都闪一下空名字。
    private let cacheKey = "still.me"

    private init() {
        if let d = UserDefaults.standard.data(forKey: cacheKey),
           let m = try? JSONDecoder().decode(Me.self, from: d) {
            me = m
        }
    }

    // MARK: 后台的几个口

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.stillStamp()
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return obj
    }

    /// 手里有票的话，问一句「这张票还认不认」。
    /// 认 → 直接进；不认 → 退回登录页（不弹错误，他看不懂）。
    @MainActor
    func restore() async {
        guard !Ticket.current.isEmpty else {
            signedIn = false
            return
        }
        var req = URLRequest(url: URL(string: base + "/api/auth/me")!)
        req.timeoutInterval = 15
        req.stillStamp()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 401 {
                // 票过期了 —— 干净退出，让他重新登一次
                Ticket.clear()
                signedIn = false
                return
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let u = obj?["user"] as? [String: Any],
               let uid = u["uid"] as? String, !uid.isEmpty {
                apply(Me(uid: uid,
                         phone: u["phone"] as? String ?? "",
                         name: u["name"] as? String ?? "",
                         owner: u["owner"] as? Bool ?? false))
                return
            }
        } catch {
            // ★ 连不上台子 == 「不知道」，**不能**当成「没登录」把人踢出去：
            //   断网时猫还得在家待着。有票就先进，台子回头再对。
            if me == nil {
                me = Me(uid: "", phone: "", name: "", owner: false)
            }
            signedIn = true
        }
    }

    @MainActor
    func register(phone: String, password: String, name: String) async {
        await run("/api/auth/reg", ["phone": phone, "password": password, "name": name])
    }

    @MainActor
    func login(phone: String, password: String) async {
        await run("/api/auth/login", ["phone": phone, "password": password])
    }

    @MainActor
    private func run(_ path: String, _ body: [String: Any]) async {
        busy = true
        error = ""
        defer { busy = false }
        do {
            let obj = try await post(path, body)
            guard obj["ok"] as? Bool == true else {
                error = obj["错误"] as? String ?? "没成功，再试一次"
                return
            }
            guard let t = obj["token"] as? String, !t.isEmpty else {
                error = "台子没给票，再试一次"
                return
            }
            Ticket.save(t)
            let u = obj["user"] as? [String: Any] ?? [:]
            apply(Me(uid: u["uid"] as? String ?? "",
                     phone: u["phone"] as? String ?? "",
                     name: u["name"] as? String ?? "",
                     owner: u["owner"] as? Bool ?? false))
        } catch {
            self.error = "连不上台子 —— 看看网络"
        }
    }

    @MainActor
    private func apply(_ m: Me) {
        me = m
        if let d = try? JSONEncoder().encode(m) {
            UserDefaults.standard.set(d, forKey: cacheKey)
        }
        signedIn = true
    }

    @MainActor
    func logout() {
        Task { _ = try? await post("/api/auth/logout", [:]) }
        Ticket.clear()
        UserDefaults.standard.removeObject(forKey: cacheKey)
        me = nil
        signedIn = false
    }
}
