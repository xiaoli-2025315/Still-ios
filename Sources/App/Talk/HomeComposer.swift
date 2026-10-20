import SwiftUI
import UIKit

// MARK: - 主页输入条（v44）
//
// ★★★ 为什么把它从「一颗『跟它说话』的大按钮」换成一条常驻输入框：
//   他原话：「不要有这个跟他说话的按键了，直接就跟豆包一样主页放个输入框就行了直接可以输入」。
//
//   按钮的问题不是难看，是**多一道路径**：点按钮 → 由我们自己弹一个系统框 →
//   那个框里的输入框还不一定拿得到键盘。输入框直接摆在主页上，
//   手指一点就是系统原生的一次聚焦 —— 中间没有我们自己的弹窗、没有转场、
//   没有「present 的 completion 里再 becomeFirstResponder」这种要靠时序的活儿。
//   路径越短，能被系统静默吃掉的地方越少。
//
// ★ 这条链上 v36→v43 反复栽的都是同一件事：键盘起不来。v43 已经把
//   「喂帧 / 播放 / 音频会话」在打字时让出去了。这里接着做两件事：
//   ① 聚焦的那一刻（`textFieldDidBeginEditing`）就让位，不等键盘动画开始 ——
//      键盘动画和按键声都要主线程和音频通道，晚一步就已经在抢了
//   ② 真起不来时，输入框下面直接写卡在哪 + 给一条能走的路
//      （通知里那个输入框在系统进程里，跟键盘无关，那条一直是通的）
//
// ★ 为什么不放在 HerPane 的 ScrollView 里：
//   滚动视图里放输入框，键盘一起来它就被滚走、或者跟着内容一起动。
//   这里是钉在页面结构里的，跟 tab 栏同一层，不乱跑。

@MainActor
struct HomeComposer: View {

    /// 键盘到底起来没有 —— 只用来显示那行兜底提示，更新很稀（开/合）
    @ObservedObject private var focus = TalkFocus.shared

    @State private var text = ""
    /// 外面推这个数 = 再抢一次焦点
    @State private var pulse = 0

    /// 刚说的那句（右侧红气泡）
    @State private var mine = ""
    /// 它回的那句（左侧白气泡）
    @State private var reply = ""
    @State private var thinking = false

    var body: some View {
        VStack(spacing: 6) {

            // 最近一轮 —— 直接摆在输入框上方，发完不用滚也能看见它答了什么。
            // 豆包那边也是这样：输入框和对话就在同一屏里。
            if thinking || !reply.isEmpty || !mine.isEmpty {
                conversation
            }

            bar

            // 键盘真起不来时的那行 —— 他不该再遇到「点了，什么都没发生」
            if !focus.keyboardUp, focus.status != "还没试过" {
                fallbackRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - 输入条本体

    private var bar: some View {
        HStack(spacing: 8) {
            TalkField(text: $text,
                      focusPulse: pulse,
                      autoFocus: false,
                      onSubmit: send,
                      onBeginEdit: beginTyping,
                      onEndEdit: endTyping)
                .frame(height: 22)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Tw.white)
                        .overlay(Capsule().stroke(Tw.gray200, lineWidth: 1))
                )

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSend ? Tw.white : Tw.gray400)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle().fill(canSend ? Tw.red600 : Tw.gray100)
                    )
            }
            .buttonStyle(PressStyle(scale: 0.92))
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !thinking
    }

    // MARK: - 最近一轮

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !mine.isEmpty {
                HStack {
                    Spacer(minLength: 44)
                    Text(mine)
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Tw.red600)
                        )
                        .lineLimit(3)
                }
            }

            if thinking || !reply.isEmpty {
                HStack {
                    Text(thinking ? "它在想…" : reply)
                        .font(.system(size: 13))
                        .foregroundStyle(thinking ? Tw.gray400 : Tw.gray900)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Tw.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Tw.gray200, lineWidth: 1)
                                )
                        )
                        .lineLimit(4)
                    Spacer(minLength: 44)
                }
            }
        }
        .transition(.opacity)
    }

    // MARK: - 兜底那一行

    private var fallbackRow: some View {
        HStack(spacing: 6) {
            Text("键盘：\(focus.status)")
                .font(.system(size: 10))
                .foregroundStyle(Tw.gray400)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                // 这条一定能用：通知上那个输入框在系统进程里，跟键盘无关。
                Notifier.askInput(after: 0.2)
            } label: {
                Text("改用通知打字")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Tw.red600)
            }
            .buttonStyle(PressStyle(scale: 0.94))
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 打字态
    //
    // ★ 让位要在**聚焦的这一刻**就做，不能等键盘通知 ——
    //   等通知到的时候，键盘动画已经在跟我们的 15 帧/秒抢主线程了。

    private func beginTyping() {
        _ = PiPController.shared?.parkForTyping()
        PiPController.shared?.quiesceForTyping()
        Diag.report("① 主页输入框拿到焦点")
    }

    private func endTyping() {
        PiPController.shared?.resumeAfterTyping()
    }

    // MARK: - 发

    private func send() {
        let m = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !thinking else { return }

        text = ""
        mine = m
        reply = ""
        thinking = true
        pulse += 1          // 发完留在输入态，想接着说就接着打

        Task { @MainActor in
            let r = await CatTalk.say(m)
            reply = r
            thinking = false
            pulse += 1
        }
    }
}
