import SwiftUI
import UIKit
import GameController

// MARK: - 现场上报（v43）
//
// ★★★ 为什么要有这个东西：
//   v36→v42 七版都在猜「键盘为什么不弹」。v42 把四个数摆到界面上，
//   但那是让他念给我听 —— 他凌晨三点在真机上点，不会一条条对着念。
//   所以这一版改成：**App 自己把现场传到台子**，我直接从服务器读。
//
// ★ 上报的时机（三个，缺一不可）：
//   ① 点「跟它说话」那一刻 —— 记「还没弹」的底
//   ② 弹窗出来 2.5 秒后    —— 键盘到底起没起，就在这一刻定
//   ③ 键盘真的出现时      —— 如果它是在 2.5 秒之后才起，也得记下来
//
// ★ 只上报、不改任何行为。上报失败也不打扰他（静默）。

@MainActor
enum Diag {

    static let base = "https://still-ui-design.app.workbuddy.host"

    /// 一次进程内的会话号 —— 同一台手机、同一次启动，几条记录能串起来看
    static let session = String(UUID().uuidString.prefix(8))

    /// 键盘通知的流水（时间 + 高度），判断"到底有没有真上来过"
    private static var kbEvents: [[String: String]] = []

    static func noteKeyboard(_ what: String, height: CGFloat) {
        let t = String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        kbEvents.append(["事件": what, "高": "\(Int(height))", "时刻": t])
        if kbEvents.count > 12 { kbEvents.removeFirst() }
    }

    // MARK: - 拍一张现场

    private static func snapshot() -> [String: Any] {
        var d: [String: Any] = [:]
        let bundle = Bundle.main

        // 谁、哪一版
        d["会话"] = session
        d["版本"] = "\(bundle.infoDictionary?["CFBundleShortVersionString"] ?? "?")"
            + "(\(bundle.infoDictionary?["CFBundleVersion"] ?? "?"))"
        d["包名"] = bundle.bundleIdentifier ?? "?"
        d["设备"] = UIDevice.current.model
        d["系统"] = UIDevice.current.systemVersion
        d["唯一号"] = UIDevice.current.identifierForVendor?.uuidString.prefix(8).description ?? "?"

        // App 在什么状态
        let st = UIApplication.shared.applicationState
        d["App状态"] = ["活跃", "半死（inactive）", "后台"][min(max(Int(st.rawValue), 0), 2)]

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        d["场景数"] = scenes.count
        if let scene = scenes.first {
            let asv = scene.activationState
            let names = ["未连接", "前台未激活", "后台", "前台活跃"]
            let i = min(max(Int(asv.rawValue), 0), 3)
            d["场景状态"] = names[i]
            d["场景窗口数"] = scene.windows.count
            d["主窗口是key"] = scene.windows.contains(where: { $0.isKeyWindow })
            d["主窗口可见"] = scene.windows.contains(where: { !$0.isHidden && $0.alpha > 0 })

            if let key = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                d["窗口层级"] = Int(key.windowLevel.rawValue)
                d["窗口尺寸"] = "\(Int(key.bounds.width))x\(Int(key.bounds.height))"
                d["窗口被挡住"] = key.isHidden
                var chain: [String] = []
                var vc = key.rootViewController
                while let v = vc {
                    chain.append(String(describing: type(of: v)))
                    vc = v.presentedViewController
                }
                d["界面链"] = chain.joined(separator: " > ")
            }
        }

        // 键盘
        d["键盘高"] = KeyboardProbe.shared.kbHeight
        d["键盘上来过"] = KeyboardProbe.shared.kbEverShown
        d["键盘流水"] = kbEvents
        d["主线程滞后"] = KeyboardProbe.shared.lagMS
        d["输入法"] = KeyboardProbe.shared.modes
        d["外接键盘"] = GCKeyboard.coalesced != nil
        d["安全区底"] = Int(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.bottom ?? -1)

        return d
    }

    // MARK: - 传上去

    /// stage 是一句人话，我在服务器上就靠它分辨这是哪一步。
    static func report(_ stage: String, extra: [String: Any] = [:]) {
        var body = snapshot()
        body["这一步"] = stage
        body["时刻"] = ISO8601DateFormatter().string(from: Date())
        for (k, v) in extra { body["@" + k] = v }

        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        else { return }

        var req = URLRequest(url: URL(string: base + "/api/diag")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12
        URLSession.shared.uploadTask(with: req, from: data) { _, _, _ in
            // 上报本身失败就失败 —— 绝不打扰他，也绝不重试（重试会把台子刷满）
        }.resume()
    }
}
