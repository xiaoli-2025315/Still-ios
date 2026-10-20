import SwiftUI
import UIKit

// MARK: - 输入条：屏幕最顶上那一条
//
// ★★ 位置照安卓 `TalkBar` 摆：安卓从 v1.60 起就钉在**屏幕最上面**，
//   注释原话「键盘从下面升起来也盖不到它」。iOS 原来那条在屏幕最底下，
//   正好是键盘升起的位置 —— 点得到、看不见。
//
// ★★★ v37 把焦点这条链整个换掉了：
//   v36 用的是 SwiftUI 的 `@FocusState`，真机上一句「键盘就是不弹」。
//   现在换成真 `UITextField`（见 TalkField.swift），直接 becomeFirstResponder，
//   而且**连着抢 8 次**。抢不到的时候会把原因写在条子下面，
//   不再出现「什么都没发生、也不知道为什么」。

struct TalkSheet: View {

    @Binding var open: Bool

    @ObservedObject private var focus = TalkFocus.shared

    @State private var text = ""
    @State private var reply: String?
    @State private var busy = false
    /// 推一下 = 再抢一次焦点
    @State private var pulse = 0
    /// 抢了几轮还没起来，才把原因亮出来（正常情况不显示，别碍眼）
    @State private var trouble = false

    private let red600 = Color(hex: 0xDC2626)     // Tailwind red-600
    private let gray900 = Color(hex: 0x111827)    // gray-900
    private let gray400 = Color(hex: 0x9CA3AF)    // gray-400
    private let gray500 = Color(hex: 0x6B7280)    // gray-500

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TalkField(text: $text, focusPulse: pulse, onSubmit: send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { grab() }

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
                .buttonStyle(PressStyle(scale: 0.94))
                .disabled(busy)

                Button(action: close) {
                    Text("收起")
                        .font(.system(size: 13))
                        .foregroundStyle(gray500)
                        .padding(.vertical, 6)
                        .padding(.leading, 2)
                }
                .buttonStyle(PressStyle(scale: 0.94))
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

            // 抢不到键盘时，把卡在哪一步写出来。正常不显示。
            if trouble && !focus.keyboardUp {
                Text("键盘没起来：\(focus.status)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(gray400)
                    .padding(.horizontal, 14)
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
        .onAppear(perform: kick)
        .onChange(of: open) { if open { kick() } }
    }

    // MARK: - 抢焦点
    //
    // ★ 只推一次不够。视图刚上屏那一瞬 window 可能还是 nil，
    //   系统会把这一次 becomeFirstResponder 静默丢掉。
    //   所以按 0 / 0.2 / 0.6 / 1.1 / 1.8 秒各推一次，
    //   每一次都走 TalkFocus 里那 8 连抢。

    private func kick() {
        trouble = false
        pulse += 1
        for (i, d) in [0.2, 0.6, 1.1, 1.8].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                guard self.open else { return }
                self.pulse += 1
                if i == 3 { self.trouble = true }
            }
        }
    }

    private func grab() {
        pulse += 1
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
            pulse += 1          // 发完还留在输入态，想接着说就接着打
        }
    }

    private func close() {
        TalkFocus.shared.resign()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        withAnimation(.easeInOut(duration: 0.18)) { open = false }
    }
}

// MARK: - 按下去看得见
//
// ★ 为什么加这个：他说「按钮都是假的」。
//   之前全部用 `.buttonStyle(.plain)`，按下去**一点变化都没有** ——
//   哪怕动作执行了，看起来也像没反应。
//   现在按下去会缩一点、暗一点：按到了就是按到了。

struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
