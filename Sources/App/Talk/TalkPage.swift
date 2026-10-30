import SwiftUI
import UIKit

// MARK: - 对话页（全屏）
//
// ★★★ v38 为什么把它从「一条飘在顶上的输入条」改成**一整页**：
//
//   顶部那条从 v36 折腾到 v37，两个版本都死在「键盘不弹」。复盘下来，
//   它踩的全是同一类坑：浮动视图 + 转场动画 + 顶部贴边 + 外部推焦点 ——
//   每一环都可能被系统静默吞掉，而且吞掉之后**什么都不报**，只能靠猜。
//
//   一整页没有这些坑：标准页面、输入条钉在底部、键盘升起时系统自己顶上来。
//   这是 iOS 上最不会出错的一种布局，做了十几年都是这么做的。
//
//   顺带，安卓那边本来也有一整个 `TalkActivity`（聊天页）——
//   这一页正好把它补上，两边对齐。

struct TalkPage: View {

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var focus = TalkFocus.shared

    @State private var text = ""
    @State private var lines: [Line] = []
    @State private var busy = false
    /// 外面推这个数 = 再抢一次焦点
    @State private var pulse = 0
    /// ★ 2026-10-30：语音模式（左边那颗切换）—— 对齐安卓聊天页
    @State private var voiceMode = false

    struct Line: Identifiable {
        let id = UUID()
        let mine: Bool
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            dialog
        }
        .background(Tw.gray50.ignoresSafeArea())
        // ★ 输入条钉在底部 + safeAreaInset：键盘一升，系统把它整条顶起来，
        //   不用自己算键盘高度，也不会被挡住。
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .onAppear(perform: boot)
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("跟它还说话")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(busy ? "它在想…" : "说一句，它就应一句")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - 聊天记录

    private var dialog: some View {
        ScrollViewReader { sp in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还没聊过")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Tw.gray900)
                            Text("下面说第一句，它就会记住")
                                .font(.system(size: 12))
                                .foregroundStyle(Tw.gray400)
                        }
                        .padding(.top, 18)
                    }
                    ForEach(lines) { l in
                        bubble(l).id(l.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.count) {
                withAnimation(.easeOut(duration: 0.18)) { sp.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func bubble(_ l: Line) -> some View {
        HStack {
            if l.mine { Spacer(minLength: 40) }
            Text(l.text)
                .font(.system(size: 14))
                .foregroundStyle(l.mine ? Tw.white : Tw.gray900)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(l.mine ? Tw.red600 : Tw.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(l.mine ? Color.clear : Tw.gray200, lineWidth: 1)
                )
                .textSelection(.enabled)
            if !l.mine { Spacer(minLength: 40) }
        }
    }

    // MARK: - 底部输入条
    //
    // 形态照安卓 `TalkBar`：白底圆角 + 右边一块红的「说」。

    private var inputBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // 左：键盘 / 语音 切换（安卓那颗「语音」）
                Button {
                    voiceMode.toggle()
                    if voiceMode { focus.resign() }
                } label: {
                    Text(voiceMode ? "键盘" : "语音")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Tw.gray500)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                }
                .buttonStyle(PressStyle(scale: 0.94))

                if voiceMode {
                    // 语音模式：整条就是录音键（按住说、上滑取消、太短提示都在 PawTalkButton 里）
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Tw.gray50)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Tw.gray200, lineWidth: 1))
                        HStack(spacing: 8) {
                            PawTalkButton(onSaid: { t in
                                text = t
                                send()
                            })
                            Text("按住 说话")
                                .font(.system(size: 13.5))
                                .foregroundStyle(Tw.gray500)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 10)
                    }
                    .frame(height: 46)
                } else {
                // ★ 2026-10-30：**固定一行高**。以前它没有高度约束，
                //   在没历史消息时会把整页撑成一大块白框（他截图里那个"巨大的空框"）。
                TalkField(text: $text, focusPulse: pulse, autoFocus: true,
                          onSubmit: send,
                          onBeginEdit: { PiPController.shared?.quiesceForTyping() },
                          onEndEdit: { PiPController.shared?.resumeAfterTyping() })
                    .frame(height: 22)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Tw.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Tw.gray200, lineWidth: 1)
                            )
                    )

                Button(action: send) {
                    Text("说")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Tw.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(busy ? Tw.red600.opacity(0.45) : Tw.red600)
                        )
                }
                .buttonStyle(PressStyle(scale: 0.94))
                .disabled(busy)
                }
            }

        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            Tw.white
                .overlay(alignment: .top) {
                    Rectangle().fill(Tw.gray200).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - 起

    private func boot() {
        // ★ v48：整段记录都摆出来（以前只有最后一句）。
        //   老数据只有 last 那一句 —— 记录是空的就退回它，别让人以为记录被清了。
        let rows = ChatLog.all()
        if rows.isEmpty, let t = CatTalk.last() {
            lines = [Line(mine: true, text: t.mine), Line(mine: false, text: t.reply)]
        } else {
            lines = rows.flatMap {
                [Line(mine: true, text: $0.you), Line(mine: false, text: $0.cat)]
            }
        }
        // AutoField 一上屏会自己抢；这几下是补刀，间隔拉开、不跟系统抢。
        for d in [0.25, 0.7, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { pulse += 1 }
        }
    }

    private func close() {
        TalkFocus.shared.resign()
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        // ★ v44：这一页也「让位」了（停喂帧、停播放、松开音频会话），
        //   视图被移除时不一定走 didEndEditing —— 这里显式还回去，
        //   否则进过一次聊天记录，猫的画和声音就一直停着。
        PiPController.shared?.resumeAfterTyping()
        dismiss()
    }

    // MARK: - 发

    private func send() {
        let m = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !busy else { return }

        text = ""
        busy = true
        lines.append(Line(mine: true, text: m))
        pulse += 1                     // 发完还留在输入态，想接着说就接着打

        Task { @MainActor in
            let reply = await CatTalk.say(m)
            lines.append(Line(mine: false, text: reply))
            busy = false
            pulse += 1
        }
    }
}
