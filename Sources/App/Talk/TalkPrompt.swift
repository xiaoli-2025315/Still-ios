import SwiftUI
import UIKit

// MARK: - 系统输入框
//
// ★★★ 为什么落到这里（v39）：
//   v36 顶部飘一条 SwiftUI TextField、v37 真 UITextField 连抢 8 次、
//   v38 一整页 safeAreaInset —— 三种布局全都「键盘不弹、且不报错」。
//   所以改用系统自己的弹窗（UIAlertController + addTextField）：
//   弹窗、键盘、谁该拿焦点全由系统管，我们只收字。
//
// ★★★ v40 又补了两条（他这轮的真机反馈）：
//   他说「弹出来之后键盘始终拉不出来，但屏幕外那个通知可以」。
//   两者唯一的差别是：通知那条输入框在**系统进程**里，我们这条在我们进程里，
//   而那一刻**小窗正开着**。小窗在跑的时候系统会压住我们这边的键盘。
//   ⇒ ① 弹之前先把小窗收掉，打完再还（PiPController.parkForTyping）
//     ② 窗口必须是 key，否则键盘不理我们
//     ③ 盯 1.5 秒：键盘还是没起，就**自动转成那条已经能用的路**（发通知去打字），
//        不再出现「弹出来、打不了、也没人说一句」。
//
// ★ 一个坑：`becomeFirstResponder()` 必须在 **present 的 completion** 里调。
//   在 present 之前调，视图还没上屏，系统直接忽略（又是静默失败）。

@MainActor
enum TalkPrompt {

    /// 弹出系统输入框。
    /// - Parameters:
    ///   - preset: 预填内容（一般是上一句，方便改一下再说）
    ///   - onFallback: 键盘最后没起来、已自动转成通知输入时调一次（用来给用户一句实话）
    ///   - onSend: 按「说」之后把文字交回来（已 trim，非空）
    static func ask(title: String = "跟它说句话",
                    message: String = "写一句，它就在这儿听着。",
                    preset: String = "",
                    sendTitle: String = "说",
                    onFallback: (@MainActor () -> Void)? = nil,
                    onSend: @escaping @MainActor (String) -> Void) {

        // ① 小窗先收 —— 它在跑的时候，我们这边要不到键盘。
        let pipWasOpen = PiPController.shared?.parkForTyping() ?? false
        // 收小窗要一小会儿（系统那个窗口是淡出的），等它退干净再弹，别抢时间。
        let delay: TimeInterval = pipWasOpen ? 0.5 : 0.0

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let session = Session(pipWasOpen: pipWasOpen,
                                  onFallback: onFallback,
                                  onSend: onSend)
            session.start(title: title, message: message,
                          preset: preset, sendTitle: sendTitle)
        }
    }

    /// 只报个信（回话太长、或者不想用通知的时候）。
    static func tell(_ text: String, title: String, done: @escaping @MainActor () -> Void = {}) {
        guard let host = Session.topViewController() else { done(); return }
        let a = UIAlertController(title: title, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "嗯", style: .default) { _ in
            MainActor.assumeIsolated { done() }
        })
        host.present(a, animated: true)
    }

    // MARK: - 一次输入就是一次 session（省得几个闭包里抢状态）

    @MainActor
    private final class Session {

        private var alert: UIAlertController!
        private let pipWasOpen: Bool
        private let onSend: @MainActor (String) -> Void
        private let onFallback: (@MainActor () -> Void)?

        /// 已经收场了（点「说」/ 点「算了」/ 自动转通知，三者只算一次）
        private var closed = false
        /// 键盘出现的观测；非 nil = 还在等键盘
        private var watch: NSObjectProtocol?

        init(pipWasOpen: Bool,
             onFallback: (@MainActor () -> Void)?,
             onSend: @escaping @MainActor (String) -> Void) {
            self.pipWasOpen = pipWasOpen
            self.onFallback = onFallback
            self.onSend = onSend
        }

        func start(title: String, message: String, preset: String, sendTitle: String) {
            guard let host = Self.topViewController() else {
                // 连能挂弹窗的界面都找不到 —— 直接走那条一定能用的路
                fallback(reason: "界面没找着")
                return
            }

            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert = a

            a.addTextField { f in
                f.placeholder = "说点什么…"
                f.text = preset
                f.autocorrectionType = .no
                f.spellCheckingType = .no
                f.returnKeyType = .send
                f.clearButtonMode = .whileEditing
            }

            let send = UIAlertAction(title: sendTitle, style: .default) { _ in
                // UIAlertAction 的回调没标 @MainActor，但它一定在主线程上跑。
                MainActor.assumeIsolated {
                    self.submit()
                }
            }
            a.addAction(UIAlertAction(title: "算了", style: .cancel) { _ in
                MainActor.assumeIsolated { self.cancel() }
            })
            a.addAction(send)
            a.preferredAction = send   // 键盘上的 return 直接走「说」

            host.present(a, animated: true) {
                self.afterPresent()
            }
        }

        // MARK: - 弹出来之后

        private func afterPresent() {
            // ② 窗口必须是 key。不是 key 的话 becomeFirstResponder 会「成功」但不弹键盘。
            if let w = alert.view.window, !w.isKeyWindow { w.makeKey() }
            alert.textFields?.first?.becomeFirstResponder()

            // 补两刀（系统偶尔吃掉第一刀，静默的那种）
            for d in [0.18, 0.55] {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                    guard !self.closed, !self.alert.isBeingDismissed else { return }
                    let f = self.alert.textFields?.first
                    if f?.isFirstResponder != true { f?.becomeFirstResponder() }
                }
            }

            // ③ 盯键盘：起来了就撤掉这个哨兵；没起来就自动转通知。
            watch = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { self.clearWatch() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard self.watch != nil, !self.closed else { return }
                self.clearWatch()
                self.fallback(reason: "键盘没起来")
            }
        }

        // MARK: - 收场

        private func submit() {
            guard !closed else { return }
            closed = true
            clearWatch()
            let raw = alert.textFields?.first?.text ?? ""
            let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            restorePiP(after: 0.6)
            guard !m.isEmpty else { return }
            onSend(m)
        }

        private func cancel() {
            guard !closed else { return }
            closed = true
            clearWatch()
            restorePiP(after: 0)
        }

        /// 键盘这条路走不通 —— 把弹窗安静收掉，改用通知输入（那条已经真机验过能用）。
        private func fallback(reason: String) {
            guard !closed else { return }
            closed = true
            clearWatch()

            let hand: () -> Void = {
                self.restorePiP(after: 0)
                self.onFallback?()
                Notifier.askInput(after: 0.5)
            }
            if alert != nil, alert.view.window != nil {
                alert.dismiss(animated: false) { hand() }
            } else {
                hand()
            }
        }

        private func clearWatch() {
            if let w = watch {
                NotificationCenter.default.removeObserver(w)
                watch = nil
            }
        }

        private func restorePiP(after seconds: TimeInterval) {
            guard pipWasOpen else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                PiPController.shared?.unparkAfterTyping(true)
            }
        }

        // MARK: - 找最上面那一层

        /// 从当前活跃窗口一路往上找到最顶上的 present 链尾部。
        /// 不找到它就直接 present，会在「已经有东西在弹」的时候静默失败。
        fileprivate static func topViewController() -> UIViewController? {
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
}
