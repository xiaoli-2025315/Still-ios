import SwiftUI
import UIKit

// MARK: - 键盘真实高度（让输入框跟着键盘走）
//
// ★ 2026-11-24：他报「点输入框拉起键盘，输入框不往上走、被键盘盖住了」。
//   聊天页早先把键盘交给系统 safeAreaInset（1.188 那次），但在 fullScreenCover 里
//   那套不顶；「它」页的制作动作面板是底部浮层，更是直接被盖。两端都自己读键盘高度，
//   输入区按它抬高，键盘一收就归零 —— 不猜、不靠动画时序。
//
//   这是**唯一的键盘高度真源**，只读系统通知，不碰任何业务逻辑。
@MainActor
final class KeyboardHeight: ObservableObject {
    static let shared = KeyboardHeight()

    /// 键盘现在占了多少点。0 = 收起。
    @Published private(set) var 高: CGFloat = 0

    private var obs: [NSObjectProtocol] = []

    private init() {
        let c = NotificationCenter.default
        // willChangeFrame 在键盘弹出/收起/换输入法时都会给终态 frame，够跟手。
        obs.append(c.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                 object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self,
                      let v = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
                else { return }
                let f = v.cgRectValue
                let 屏高 = UIScreen.main.bounds.height
                // frame 落到屏幕底边＝收起；否则高度＝屏底 - frame 顶
                let h = max(0, 屏高 - f.origin.y)
                self.高 = h > 60 ? h : 0
            }
        })
        obs.append(c.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.高 = 0 }
        })
    }

    deinit { obs.forEach { NotificationCenter.default.removeObserver($0) } }
}
