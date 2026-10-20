import SwiftUI
import UIKit

// MARK: - 系统输入框
//
// ★★★ 为什么最后落到这里（v39）：
//
//   在 App 里「弹不出键盘」这件事，v36 / v37 / v38 试过三种做法全都失败：
//     v36 顶部飘一条 SwiftUI TextField（等系统自己聚）
//     v37 顶部飘一条真 UITextField + 连抢 8 次焦点
//     v38 一整页对话页 + safeAreaInset + didMoveToWindow 里抢
//   三次都死在同一个地方：**键盘就是不弹，而且不报错**。
//   这说明问题不在「哪一种布局」，而在我们自己造的那套视图树里。
//
//   `UIAlertController` 是系统自己的弹窗。它的输入框、它的键盘、
//   它的「谁该拿焦点」，全由系统管 —— 我们只负责把字收回来。
//   这条路十几年没变过，**只要 alert 能弹出来，键盘一定会弹**。
//
//   所以定位变了：
//     · 打字 → 系统弹窗（这里），一定能打
//     · 看记录 / 连续聊 → 对话页（TalkPage），能开就用，开不了也不影响说话
//
// ★ 一个坑：`becomeFirstResponder()` 必须在 **present 的 completion** 里调。
//   在 present 之前调，视图还没上屏，系统直接忽略（又是静默失败）。

@MainActor
enum TalkPrompt {

    /// 弹出系统输入框。
    /// - Parameters:
    ///   - preset: 预填内容（一般是上一句，方便改一下再说）
    ///   - onSend: 按「说」之后把文字交回来（已 trim，非空）
    static func ask(title: String = "跟它说句话",
                    message: String = "写一句，它就在这儿听着。",
                    preset: String = "",
                    sendTitle: String = "说",
                    onSend: @escaping @MainActor (String) -> Void) {

        guard let host = topViewController() else { return }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        alert.addTextField { f in
            f.placeholder = "说点什么…"
            f.text = preset
            f.autocorrectionType = .no
            f.spellCheckingType = .no
            f.returnKeyType = .send
            f.clearButtonMode = .whileEditing
        }

        let send = UIAlertAction(title: sendTitle, style: .default) { _ in
            // UIAlertAction 的回调没有标 @MainActor，但它一定在主线程上跑。
            // 用 assumeIsolated 明确告诉编译器「这一刻确实在主线程」。
            MainActor.assumeIsolated {
                let raw = alert.textFields?.first?.text ?? ""
                let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !m.isEmpty else { return }
                onSend(m)
            }
        }

        alert.addAction(UIAlertAction(title: "算了", style: .cancel))
        alert.addAction(send)
        // 回车 = 按「说」。键盘上的 return 会走这里。
        alert.preferredAction = send

        host.present(alert, animated: true) {
            // ★ 只有这一刻，输入框是真的在屏幕上了。
            alert.textFields?.first?.becomeFirstResponder()
        }
    }

    /// 只报个信（回话太长、或者不想用通知的时候）。
    static func tell(_ text: String, title: String, done: @escaping @MainActor () -> Void = {}) {
        guard let host = topViewController() else { done(); return }
        let a = UIAlertController(title: title, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "嗯", style: .default) { _ in
            MainActor.assumeIsolated { done() }
        })
        host.present(a, animated: true)
    }

    // MARK: - 找最上面那一层

    /// 从当前活跃窗口一路往上找到最顶上的 present 链尾部。
    /// 不找到它就直接 present，会在「已经有东西在弹」的时候静默失败。
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene else { return nil }

        var vc = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene.windows.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }

        // 已经是 alert 了就别再叠一层（连点两下会叠成两个框）
        if vc is UIAlertController { return nil }
        return vc
    }
}
