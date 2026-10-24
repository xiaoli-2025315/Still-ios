import SwiftUI
import UIKit

// MARK: - 抢键盘
//
// ★★★ 为什么不再用 SwiftUI 的 `@FocusState`：
//   它在三种情况下会被系统**静默忽略**（不报错、不崩、什么都不发生）——
//   ① 视图刚插进视图树、还没有 window
//   ② 外面套了动画 / transition
//   ③ 整棵树在高频刷新（我们的引擎 30Hz 刷新过一遍，正好踩中）
//   表现就是他一直说的那句：「条子出来了，键盘就是不弹。」
//
//   这里换成真 `UITextField` + 直接 `becomeFirstResponder()`，
//   并且**连续抢几次**（前几次经常被系统吃掉），不成功就记下原因。
//   原因会显示在输入条上 —— 真机上第一眼就能看出卡在哪一步，不用猜。

final class TalkFocus: ObservableObject {

    static let shared = TalkFocus()

    /// 键盘到底起来了没有（监听系统通知，不靠猜）
    @Published private(set) var keyboardUp = false
    /// 最后一次抢焦点的结果，给界面上一行小字用
    @Published private(set) var status = "还没试过"

    private weak var field: UITextField?
    private var tries = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        let c = NotificationCenter.default
        observers.append(c.addObserver(forName: UIResponder.keyboardDidShowNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            self?.keyboardUp = true
            self?.status = "键盘已弹出"
        })
        observers.append(c.addObserver(forName: UIResponder.keyboardDidHideNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            self?.keyboardUp = false
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func register(_ f: UITextField) {
        field = f
    }

    /// 立刻抢，抢不到就连着再抢 8 次（0.2 秒一次）。
    func claim() {
        tries = 0
        attempt()
    }

    private func attempt() {
        tries += 1
        guard let f = field else {
            status = "输入框还没建出来"
            return
        }
        if f.isFirstResponder {
            status = "已拿到焦点"
            return
        }
        guard f.window != nil else {
            status = "输入框还没上屏（第 \(tries) 次）"
            if tries < 8 { retry() }
            return
        }
        let ok = f.becomeFirstResponder()
        if ok {
            status = keyboardUp ? "键盘已弹出" : "已拿到焦点，等键盘（第 \(tries) 次）"
        } else {
            status = "becomeFirstResponder 被拒（第 \(tries) 次）"
            if tries < 8 { retry() }
        }
    }

    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.keyboardUp else { return }
            self.attempt()
        }
    }

    func resign() {
        field?.resignFirstResponder()
        status = "收起了"
    }
}

// MARK: - 输入框本体
//
// ★★ v38 又加了一条兜底：`AutoField.didMoveToWindow`。
//   前面那套「外面按节奏推 pulse、里面连抢 8 次」是外部驱动 —— 只要中间有一环没跑，
//   键盘就还是不弹。`didMoveToWindow` 是**系统自己来通知**「我现在真的在屏幕上了」，
//   在那一刻抢，是整条链上唯一不依赖我们自己计时的时机。
//   两条都留着：它先进，外部推的几次就当补刀。

final class AutoField: UITextField {

    /// 一上屏就自己抢焦点。真正的「不用点」。
    var autoFocus = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard autoFocus, window != nil else { return }
        // 同一轮 runloop 里抢会被系统吞掉（视图还没完成布局），推到下一轮。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }
}

struct TalkField: UIViewRepresentable {

    @Binding var text: String
    /// 每次自增 = 再抢一次焦点（外面按节奏推这个数）
    var focusPulse: Int
    /// 一上屏就抢。全屏对话页用它 —— 打开就该能打字。
    var autoFocus: Bool = false
    /// 框里那句灰字
    var placeholder: String = "说点什么…"
    var onSubmit: () -> Void
    /// ★ v44：拿到焦点 / 丢掉焦点。主页输入条用它来「让位」
    ///   （停喂帧、停播放、把音频会话交还系统）—— 让位要在聚焦这一刻做，
    ///   等键盘通知到的时候，键盘动画已经在跟画面抢主线程了。
    var onBeginEdit: () -> Void = {}
    var onEndEdit: () -> Void = {}

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> UITextField {
        let f = AutoField()
        f.autoFocus = autoFocus
        f.placeholder = placeholder
        f.font = .systemFont(ofSize: 14)
        f.textColor = UIColor(red: 0x11 / 255.0, green: 0x18 / 255.0, blue: 0x27 / 255.0, alpha: 1)
        f.tintColor = UIColor(red: 0xDC / 255.0, green: 0x26 / 255.0, blue: 0x26 / 255.0, alpha: 1)
        f.borderStyle = .none
        f.returnKeyType = .send
        f.autocorrectionType = .no
        f.spellCheckingType = .no
        f.textContentType = nil
        f.delegate = context.coordinator
        f.addTarget(context.coordinator,
                    action: #selector(Coord.editingChanged(_:)),
                    for: .editingChanged)
        // 别让它把「说」和「收起」挤掉
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        TalkFocus.shared.register(f)
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        if f.text != text { f.text = text }
        if context.coordinator.pulse != focusPulse {
            context.coordinator.pulse = focusPulse
            TalkFocus.shared.claim()
        }
    }

    final class Coord: NSObject, UITextFieldDelegate, UIGestureRecognizerDelegate {
        var parent: TalkField
        var pulse = 0

        /// ★ 2026-10-24（他报的「输入框一旦拉起来，就没有一个地方能让它降下来」）：
        ///   打字期间在整个窗口上挂一个「点一下」的手势 —— **点主页任意一处都收键盘**，
        ///   只有点在输入框自己身上不收（那是在挪光标）。
        ///   `cancelsTouchesInView = false` ⇒ 主页上的按钮、tab 照常点得动，
        ///   手势只是"顺手收个键盘"，不抢任何点击。
        private weak var tap: UITapGestureRecognizer?
        private weak var field: UITextField?

        init(_ p: TalkField) { parent = p }

        @objc func editingChanged(_ f: UITextField) {
            parent.text = f.text ?? ""
        }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        func textFieldDidBeginEditing(_ f: UITextField) {
            parent.onBeginEdit()
            installTap(f)
        }

        func textFieldDidEndEditing(_ f: UITextField) {
            parent.onEndEdit()
            removeTap()
        }

        private func installTap(_ f: UITextField) {
            guard tap == nil else { return }
            guard let w = f.window else {
                // 极少数情况下这一刻还没上屏，下一轮再挂
                DispatchQueue.main.async { [weak self, weak f] in
                    guard let self, let f else { return }
                    self.installTap(f)
                }
                return
            }
            let g = UITapGestureRecognizer(target: self, action: #selector(anywhereTapped(_:)))
            g.cancelsTouchesInView = false
            g.delegate = self
            w.addGestureRecognizer(g)
            tap = g
            field = f
        }

        private func removeTap() {
            if let g = tap { g.view?.removeGestureRecognizer(g) }
            tap = nil
            field = nil
        }

        @objc private func anywhereTapped(_ g: UITapGestureRecognizer) {
            guard let f = field else { return }
            // 点在输入框自己身上 = 挪光标，别收
            if f.bounds.contains(g.location(in: f)) { return }
            f.resignFirstResponder()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true    // 别跟页面里的滚动 / 按钮抢
        }
    }
}
