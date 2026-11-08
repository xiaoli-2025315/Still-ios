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
    /// ★ 2026-10-31：左边那颗「猫列表」（安卓聊天页有侧栏，iOS 只有一只）
    @State private var showCats = false
    @State private var cats: [ActLab.Char] = []
    @State private var switching = ""

    // 群聊：入口、挑中的猫、建群中、加载中、失败提示；标题上的群名（空 = 单聊）
    @State private var showNewGroup = false
    @State private var groupCats: [ActLab.Char] = []
    @State private var picked: Set<String> = []
    @State private var creating = false
    @State private var loadingGroup = false
    @State private var groupErr: String? = nil
    @State private var groupTitle = ""

    struct Line: Identifiable {
        let id = UUID()
        let mine: Bool
        var text: String
        var cost: String? = nil     // 回复下面那行小字，拿不到花费就不显示
        var speaker: String? = nil  // 群聊里回话的那只猫
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            groupBar
            dialog
        }
        .background(Tw.gray50.ignoresSafeArea())
        // ★ 输入条钉在底部 + safeAreaInset：键盘一升，系统把它整条顶起来，
        //   不用自己算键盘高度，也不会被挡住。
        .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
        .onAppear(perform: boot)
        .sheet(isPresented: $showCats) { catList }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            // ★ 2026-10-31：左边那颗「换一只」—— 安卓聊天页左边是猫列表
            Button {
                showCats = true
                loadCats()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

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
                Text(groupTitle.isEmpty ? "跟它还说话" : groupTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(busy ? "它在想…" : (groupTitle.isEmpty ? "说一句，它就应一句" : "几只猫一起听着"))
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
            VStack(alignment: l.mine ? .trailing : .leading, spacing: 3) {
                if !l.mine, let s = l.speaker, !s.isEmpty {
                    Text(s)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                }
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
                // 每条回复下面一行小字：这次花了多少，只显示台子真给的数。
                if !l.mine, let c = l.cost {
                    Text(c)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                }
            }
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
                    // ★ 2026-10-31（他报的）：原来只有那颗小话筒能按，**整条按不了**。
                    //   现在整条就是录音键：按住说、上滑取消、<0.6 秒提示太短；
                    //   说话时整条上显示 24 根真音波（跟安卓一样）。
                    TalkHoldBar(onSaid: { t in
                        text = t
                        send()
                    })
                    .frame(height: 46)
                } else {
                // ★ 2026-10-30：**固定一行高**。以前它没有高度约束，
                //   在没历史消息时会把整页撑成一大块白框（他截图里那个"巨大的空框"）。
                TalkField(text: $text, focusPulse: pulse, autoFocus: false,
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

    // MARK: - 群聊

    /// 常驻的一排：左边进群、右边回单聊。两个口子一直都在，不藏在条件里。
    private var groupBar: some View {
        HStack(spacing: 12) {
            Button {
                showNewGroup = true
                loadGroupCats()
            } label: {
                Text("＋ 新建群聊")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Tw.red600)
            }
            .buttonStyle(PressStyle(scale: 0.94))

            Spacer(minLength: 0)

            Button {
                leaveGroup()
            } label: {
                Text("回到单聊")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Tw.gray500)
            }
            .buttonStyle(PressStyle(scale: 0.94))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Tw.white)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tw.gray200).frame(height: 0.5)
        }
        .sheet(isPresented: $showNewGroup) { newGroupSheet }
    }

    /// 挑猫建群的那一页。
    private var newGroupSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let e = groupErr {
                    Text(e)
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.red600)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                } else if creating {
                    Text("正在把猫凑到一起…")
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.gray400)
                        .padding()
                } else if loadingGroup {
                    Text("正在把猫找来…")
                        .font(.system(size: 13))
                        .foregroundStyle(Tw.gray400)
                        .padding()
                } else if picked.count < 2 {
                    Text("多挑几只，才好一起聊")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .padding(.vertical, 8)
                }
                List {
                    ForEach(groupCats) { c in
                        Button {
                            togglePick(c.id)
                        } label: {
                            HStack(spacing: 10) {
                                Text(c.title)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Tw.gray900)
                                Spacer()
                                if picked.contains(c.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Tw.red600)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("拉几只猫一起聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关上") { showNewGroup = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("建群") { Task { await createGroup() } }
                        .disabled(picked.count < 2 || creating)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func togglePick(_ id: String) {
        if picked.contains(id) { _ = picked.remove(id) }
        else { _ = picked.insert(id) }
    }

    private func loadGroupCats() {
        picked = []
        groupErr = nil
        loadingGroup = true
        Task {
            do {
                let list = try await ActLab.chars()
                groupCats = list.filter { $0.dropped != true }
            } catch {
                groupErr = "没连上，等会儿再试"
            }
            loadingGroup = false
        }
    }

    @MainActor
    private func createGroup() async {
        guard picked.count >= 2, !creating else { return }
        creating = true
        groupErr = nil
        defer { creating = false }
        let chosen = groupCats.filter { picked.contains($0.id) }
        let ids = chosen.map { $0.id }
        var names: [String: String] = [:]
        for c in chosen { names[c.id] = c.title }
        if let number = await CatBrain.createGroup(members: ids, names: names) {
            CatBrain.saveGroup(number: number, members: ids, names: names,
                               title: CatBrain.groupDefaultTitle)
            groupTitle = CatBrain.groupDefaultTitle
            showNewGroup = false
        } else {
            groupErr = "没连上，等会儿再试"
        }
    }

    /// 退出群聊 / 回到单聊：清空当前群号（单聊时点了也无害）。
    private func leaveGroup() {
        CatBrain.clearGroup()
        groupTitle = ""
        showNewGroup = false
    }

    /// 左边那张「猫列表」—— 点一只就换成它来聊（对齐安卓聊天页的侧栏）
    private var catList: some View {
        NavigationStack {
            List {
                ForEach(cats) { c in
                    Button {
                        Task { await pick(c) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(c.name)
                                .font(.system(size: 15))
                                .foregroundStyle(Tw.gray900)
                            Spacer()
                            if c.id == CatBrain.currentCharId {
                                Text("在用")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Tw.gray400)
                            } else if switching == c.id {
                                Text("在换…").font(.system(size: 11)).foregroundStyle(Tw.gray400)
                            }
                        }
                    }
                }
            }
            .navigationTitle("跟谁聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关上") { showCats = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadCats() {
        Task {
            if let list = try? await ActLab.chars() {
                cats = list.filter { $0.dropped != true }
            }
        }
    }

    @MainActor
    private func pick(_ c: ActLab.Char) async {
        guard c.id != CatBrain.currentCharId else { showCats = false; return }
        switching = c.id
        defer { switching = "" }
        do {
            let pack = try await CatPackStore.shared.install(charId: c.id)
            CatPackStore.shared.use(pack)
            CatBrain.currentCharId = c.id
            showCats = false
            lines = []
            boot()
        } catch {
            // 换失败就留在原地，不改当前这只
        }
    }

    private func boot() {
        // 冷启动把上次那个群找回来；单聊就是空标题。
        CatBrain.loadGroup()
        groupTitle = CatBrain.group?.title ?? ""
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
        // ★ 2026-10-31（他要求）：进聊天**不要**自动拉起键盘，点了输入框才起。
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
        // 先摆一条空回复，流式收到字就往这条里填（主聊天页边收边显示）。
        let waiting = Line(mine: false, text: "（它在想…）")
        lines.append(waiting)
        let rid = waiting.id
        pulse += 1                     // 发完还留在输入态，想接着说就接着打

        Task { @MainActor in
            let reply = await CatTalk.say(m,
                onStream: { full in
                    // 台子给的「当前完整回话」直接写进去（片段已追加、重来已替换）。
                    if let i = lines.firstIndex(where: { $0.id == rid }) {
                        lines[i].text = full
                    }
                },
                onFinish: { cost in
                    if let cost,
                       let i = lines.firstIndex(where: { $0.id == rid }) {
                        lines[i].cost = cost
                    }
                })
            // 用返回值做最后对齐：中文错误提示、或断网回落的本地猫话，都落进气泡。
            if let i = lines.firstIndex(where: { $0.id == rid }) {
                lines[i].text = reply
                if CatBrain.group != nil {
                    lines[i].speaker = CatTalk.lastSpeakerName
                }
            }
            busy = false
            pulse += 1
        }
    }
}
