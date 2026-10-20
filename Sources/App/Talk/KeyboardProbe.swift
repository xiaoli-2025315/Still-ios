import SwiftUI
import UIKit

// MARK: - 输入状态读数（v42）
//
// ★★★ 为什么要有这个东西：
//   v36→v41 连着六版都在改「输入框怎么摆」，每一版 CI 全绿、模拟器截图也正常，
//   可真机上键盘就是起不来。**因为整条验证链里根本没有「键盘」这一项** ——
//   截图只看猫，不看键盘。所以每一版都是盲发，靠他装一次当测试。
//
//   这一版不再猜。把「键盘弹不弹」需要的四个数直接摆到界面上：
//     ① 键盘实际高度      0 = 根本没上来；只有几十 = 只上来了建议条（他说的 AutoFill）
//     ② App 是不是前台活跃  不是的话要键盘本来就是白要
//     ③ 主线程堵不堵       键盘弹出是一段动画，主线程忙就只画出第一层
//     ④ 键盘连没连上       有没有任何输入法被系统交给我们
//
// ★ 为什么不放在主视图里直接观察：
//   `@Published` 每变一次，观察它的 View 就整棵重建一次。
//   这个读数是按秒刷的 —— 放在主视图上，等于每秒把整棵树重建一次，
//   正好会把键盘的焦点和动画冲掉（v37 就是这么翻的车，30Hz 重建）。
//   所以：自己持有状态、自己渲染，父视图一次都不重建。

@MainActor
final class KeyboardProbe: ObservableObject {

    static let shared = KeyboardProbe()

    /// 键盘现在的真实高度。0 = 没有键盘。
    @Published private(set) var kbHeight: CGFloat = 0
    /// 键盘上来过没有（这一次 App 生命周期内）
    @Published private(set) var kbEverShown = false
    /// App 是不是前台活跃
    @Published private(set) var foreground = false
    /// 主线程最大滞后（毫秒）。正常 < 40，> 150 就是堵了。
    @Published private(set) var lagMS = 0
    /// 系统交给我们的输入法（空 = 一个都没有）
    @Published private(set) var modes = "—"

    private var started = false
    private var lastBeat = Date()
    private var worstLag = 0.0
    /// ★ KVO 的观察必须自己拿住，不然出了初始化就失效（这条踩过）
    private var stateObs: NSKeyValueObservation?

    /// 一行说人话的结论
    var verdict: String {
        if kbHeight > 120 { return "键盘起来了" }
        if kbHeight > 0 { return "只上来一条建议条（\(Int(kbHeight)) 点高）" }
        if !foreground { return "App 不是前台 —— 键盘不会来" }
        if lagMS > 150 { return "主线程堵着（滞后 \(lagMS) 毫秒）" }
        if modes == "—" || modes.isEmpty { return "系统没交给我们任何输入法" }
        return "键盘没上来（原因还看不出来，看下面四个数）"
    }

    func start() {
        guard !started else { return }
        started = true

        let c = NotificationCenter.default
        c.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                      object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.readFrame(n) }
        }
        c.addObserver(forName: UIResponder.keyboardWillShowNotification,
                      object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                self?.kbEverShown = true
                self?.readFrame(n)
            }
        }
        c.addObserver(forName: UIResponder.keyboardWillHideNotification,
                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.kbHeight = 0 }
        }

        stateObs = UIApplication.shared.observe(
            \.applicationState, options: [.initial, .new]) { [weak self] app, _ in
            let st = app.applicationState
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.foreground = st == .active }
            }
        }

        // 心跳：每 0.25 秒该响一次。实际晚了多少 = 主线程被占了多少。
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let late = max(0, now.timeIntervalSince(self.lastBeat) - 0.25)
                self.lastBeat = now
                self.worstLag = max(self.worstLag, late)
            }
        }

        // ★ 每 1.5 秒才刷一次界面 —— 心跳本身不触发重建。
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lagMS = Int(self.worstLag * 1000)
                self.worstLag = 0
                let all = UITextInputMode.activeInputModes
                    .compactMap { $0.primaryLanguage }
                self.modes = all.isEmpty ? "—" : all.prefix(2).joined(separator: " / ")
                self.foreground = UIApplication.shared.applicationState == .active
            }
        }

        foreground = UIApplication.shared.applicationState == .active
    }

    private func readFrame(_ n: Notification) {
        guard let v = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frame = v.cgRectValue
        // 转成「在这个窗口里还剩多高」—— 键盘收起来时 frame 会跑到屏幕下面，
        // 那种情况下高度算出来是 0，正好符合「没有键盘」。
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.screen else {
            kbHeight = frame.height
            return
        }
        let bottom = screen.bounds.height
        let visible = max(0, bottom - frame.minY)
        kbHeight = visible < 1 ? 0 : visible
        if kbHeight > 1 { kbEverShown = true }
    }
}

// MARK: - 摆在界面上的那一条

/// 输入体检条。自己管自己的状态，父视图不跟着重建。
///
/// ★ 标 @MainActor：`@StateObject` 的默认值是在 View 的 init 里求值的，
///   而 View 的 init 默认不在主线程隔离里 —— 不标就直接编译报错
///   （v37 / v38 连续栽过两次，都是同一个错）。
@MainActor
struct KeyboardDiagStrip: View {

    @StateObject private var probe = KeyboardProbe.shared
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(probe.kbHeight > 120 ? Color(red: 0x22/255, green: 0x9E/255, blue: 0x5A/255)
                              : Color(red: 0xDC/255, green: 0x26/255, blue: 0x26/255))
                        .frame(width: 6, height: 6)
                    Text("输入体检 · \(probe.verdict)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color(red: 0x6B/255, green: 0x72/255, blue: 0x80/255))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(red: 0x9C/255, green: 0xA3/255, blue: 0xAF/255))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 3) {
                    row("键盘高度", probe.kbHeight > 0 ? "\(Int(probe.kbHeight)) 点" : "0（没上来）")
                    row("前台活跃", probe.foreground ? "是" : "不是")
                    row("主线程滞后", "\(probe.lagMS) 毫秒")
                    row("输入法", probe.modes)
                }
                .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.62))
        )
        .onAppear { probe.start() }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0x9C/255, green: 0xA3/255, blue: 0xAF/255))
                .frame(width: 76, alignment: .leading)
            Text(v)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(red: 0x37/255, green: 0x41/255, blue: 0x51/255))
            Spacer(minLength: 0)
        }
    }
}
