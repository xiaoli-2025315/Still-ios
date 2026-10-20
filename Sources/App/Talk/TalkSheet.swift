import SwiftUI
import UIKit

// MARK: - 输入条：屏幕最顶上那一条
//
// ★★ 位置照安卓 `TalkBar` 摆，不是随手定的：
//   安卓从 v1.60 起就把它钉在**屏幕最上面**，注释写得很直白 ——
//   「这条 = 你说的（在屏幕顶上，键盘从下面升起来也盖不到它）」。
//   iOS 以前把它放在屏幕最底下，正好是键盘弹起来的位置：
//   键盘一升，它就在键盘底下，点得到、看不见。
//
// ★★ 焦点是**代码抢的**，不靠你点那一下：
//   安卓那边 `show()` 里 150ms 后自己 requestFocus + showSoftInput；
//   这边同样 —— 条子一出现就自己聚焦，键盘自己弹。
//   旧的那条常驻输入框他点了没反应（键盘不弹），这条路绕开了那一下点击。
//
// ★ 为什么留「收起」：键盘出来以后屏幕上能点的东西不多，
//   得有一个明确的口子把它收回去，别逼人去点空白处。

struct TalkSheet: View {

    @Binding var open: Bool

    @State private var text = ""
    @State private var reply: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    /// 安卓那套取样：白底、1px 细描边、圆角 24、右上一个红块写「说」。
    private let red600 = Color(hex: 0xDC2626)     // Tailwind red-600
    private let gray900 = Color(hex: 0x111827)    // gray-900
    private let gray400 = Color(hex: 0x9CA3AF)    // gray-400
    private let gray500 = Color(hex: 0x6B7280)    // gray-500

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("说点什么…", text: $text, axis: .vertical)
                    .lineLimit(1...2)
                    .font(.system(size: 14))
                    .foregroundStyle(gray900)
                    .tint(red600)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white)
                    )

                Button(action: send) {
                    Text("说")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(busy ? red600.opacity(0.5) : red600)
                        )
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button(action: close) {
                    Text("收起")
                        .font(.system(size: 13))
                        .foregroundStyle(gray500)
                        .padding(.vertical, 6)
                        .padding(.leading, 2)
                }
                .buttonStyle(.plain)
            }

            // 它刚回的那一句，贴在条子下面 —— 不用切出去看通知。
            if let r = reply {
                Text(r)
                    .font(.system(size: 12))
                    .foregroundStyle(gray500)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(hex: 0xFFFBF4))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(hex: 0xB98A5E).opacity(0.2), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
        )
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .onAppear { focusSoon() }
        .onChange(of: open) { if open { focusSoon() } }
    }

    // MARK: - 聚焦
    //
    // ★ 延迟是必要的，别改成同步：
    //   视图刚插进视图树时还没有 window，`focused = true` 会被系统忽略，
    //   表现就是「条子出来了，但键盘就是不弹」—— 跟旧版那个毛病一模一样。
    //   0.35s 是实测比较稳的位置（安卓那边用 0.15s，iOS 上要更从容一点）。
    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            focused = true
        }
        // 再补一次：从后台/小窗切回来的那一下，第一次经常被吃掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if open && !focused { focused = true }
        }
    }

    // MARK: - 发
    private func send() {
        let m = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !busy else { return }
        text = ""
        busy = true
        reply = "（它在听…）"
        Task { @MainActor in
            reply = await CatTalk.say(m)
            busy = false
            focused = true      // 发完还留在输入态，想接着说就接着打
        }
    }

    private func close() {
        focused = false
        // 先收键盘再收条子 —— 反过来会看到键盘在空中停半秒。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        withAnimation(.easeInOut(duration: 0.18)) { open = false }
    }
}
