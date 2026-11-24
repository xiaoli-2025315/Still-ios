import SwiftUI

// MARK: - 设置页
//
// ★★★ 2026-10-30：对齐安卓 `SettingsV2Activity` —— 安卓现在只有这 5 行：
//     豆包号 / 大脑 / 把这只派给别人 / 按键声 / 关于
//   顺序、文案都照抄。以前 iOS 这些散在 `StatusPanelView` 里（"现在用的号""连接大脑""换一个"），
//   现在收成一张表。

struct SettingsPage: View {
    // ★ 2026-10-30（真机闪退的真因）：根视图**没有**注入 environmentObject，
    //   用 @EnvironmentObject 一渲染就崩。跟原来那个 StatusPanelView 保持一致，直接拿单例。
    @ObservedObject private var auth = StillAuth.shared
    @Environment(\.dismiss) private var dismiss

    // 大脑的钥匙：跟 StatusPanelView 一样，每只猫一把
    @State private var brainKey = ""
    @State private var brainNote = ""
    /// 聊天钱包那一行：取不到就整行不显示。
    @State private var walletText: String? = nil
    @State private var showBrain = false
    @State private var showDispatch = false
    @State private var showTapSheet = false
    // ★ 2026-11-21：聊天输入框样式下拉（跟 TalkPage 同一个 key）
    @AppStorage(ComposerStyle.key) private var composerStyle = 1
    @State private var showComposerSheet = false
    // ★ 2026-11-24：「它记住的」已并入记忆球（主页第三格），设置页这行重复入口删掉
    @State private var showDoubao = false      // ★ 2026-11-19：「豆包号」行点开去登录/换号
    @State private var showConnector = false   // ★ 2026-11-24：连接器浮窗（常驻入口）
    // ★ OTCO 第0步：每只角色单独选 Agent（按 brainCharId 生效，跟大脑那行同一只）
    @State private var showAgent = false
    @State private var agentItems: [AgentStore.Item] = []
    @State private var agentNote = "读取中…"
    // ★ 关于 连点 5 下 = 截一张当前画面传回台子（排查用，见 ShotUploader）
    @State private var aboutTaps = 0
    @State private var aboutTapAt = Date.distantPast
    @State private var shotNote = ""

    private var brainCharId: String { CatBrain.currentCharId }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    row("豆包号", accountText, tappable: true) { showDoubao = true }
                    divider()
                    // ★ 2026-11-24 连接器（常驻入口）：填 Key / 绑豆包，让 AI 真能调外部 API
                    row("连接器", "", tappable: true) { showConnector = true }
                    divider()
                    row("大脑", brainText, tappable: true) { showBrain = true }
                    divider()
                    // ★ OTCO：这只用哪个脑子想（大白话，不写 Agent 这种英文）
                    row("用哪个脑子想", agentNote, tappable: true) { 打开脑子列表() }
                    divider()
                    row("把这只派给别人", "", tappable: true) { showDispatch = true }
                    divider()
                    row("按键声", SoundKit.tapNames[SoundKit.shared.tapKind],
                        tappable: true) { showTapSheet = true }
                    divider()
                    // ★ 2026-11-21（对齐安卓「设置 → 其他 → 聊天输入框」）：四种输入条样式
                    row("聊天输入框", ComposerStyle.names[composerStyle],
                        tappable: true) { showComposerSheet = true }
                    divider()
                    // 聊天钱包：异步问台子，取不到整行不画，不拿 0 冒充。
                    if let w = walletText {
                        walletRow(w)
                        divider()
                    }
                    // ★ 「关于」不能是 Button：row() 本身就是 Button，套一层会双按钮嵌套。
                    //   用普通行 + 点击计数：3 秒内连点 5 下 = 截当前画面传回台子。
                    HStack {
                        Text("关于")
                            .font(.system(size: 15))
                            .foregroundStyle(Cfg.Palette.ink)
                        Spacer()
                        Text(AppVersion.tag + (shotNote.isEmpty ? "" : " · " + shotNote))
                            .font(.system(size: 13))
                            .foregroundStyle(Cfg.Palette.faint)
                    }
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let now = Date()
                        if now.timeIntervalSince(aboutTapAt) > 1.5 { aboutTaps = 0 }
                        aboutTapAt = now
                        aboutTaps += 1
                        if aboutTaps >= 5 {
                            aboutTaps = 0
                            ShotUploader.upload(tag: "settings") { _, msg in
                                shotNote = msg
                            }
                        }
                    }
                    // ★ 2026-10-31：他说「没有关于」—— 这里再兜一行版本，
                    //   保证滚到底一定能看到「关于」和版本号。
                    HStack {
                        Text("关于")
                            .font(.system(size: 12))
                            .foregroundStyle(Cfg.Palette.faint)
                        Spacer()
                        Text(AppVersion.tag)
                            .font(.system(size: 12))
                            .foregroundStyle(Cfg.Palette.faint)
                    }
                    .padding(.top, 18)

                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .background(Cfg.Palette.bg.ignoresSafeArea())
            .navigationTitle("我")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关上") { dismiss() }
                }
            }
        }
        .onAppear {
            brainKey = CatBrain.key(for: brainCharId)
            refreshBrainNote()
            refreshAgentNote()
            Task { walletText = await CatBrain.walletLine() }
        }
        // 连接大脑
        .sheet(isPresented: $showBrain) {
            brainSheet
                .presentationDetents([.medium, .large])
        }
        // 豆包号：点这行去登录/换号 —— 复用已有的 DoubaoLoginPage
        .sheet(isPresented: $showDoubao) {
            DoubaoLoginPage().presentationDetents([.large])
        }
        // ★ 2026-11-24 连接器浮窗
        .sheet(isPresented: $showConnector) {
            ConnectorSheet()
        }
        // ★ OTCO：这只用哪个脑子想 —— 从台子拉真实列表，选中即改（选不了的不显示假项）
        .sheet(isPresented: $showAgent) {
            agentSheet.presentationDetents([.medium, .large])
        }
        // 把这只派给别人（分享码）—— 复用已有的 DispatchPage
        .sheet(isPresented: $showDispatch) {
            DispatchPage().presentationDetents([.large])
        }
        // 按键声：5 档 + 不要声音
        .confirmationDialog("按键声", isPresented: $showTapSheet, titleVisibility: .visible) {
            ForEach(0..<SoundKit.tapNames.count, id: \.self) { i in
                Button(SoundKit.tapNames[i]) {
                    SoundKit.shared.setTapKind(i)      // 选完当场试听
                }
            }
            Button("取消", role: .cancel) {}
        }
        // ★ 2026-11-21：聊天输入框样式（A/B/C/D），选中即写、下次进聊天生效
        .confirmationDialog("聊天输入框样式", isPresented: $showComposerSheet, titleVisibility: .visible) {
            ForEach(0..<ComposerStyle.names.count, id: \.self) { i in
                Button(ComposerStyle.names[i]) { composerStyle = i }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - OTCO：这只用哪个脑子想（每只角色单独一份）

    /// 行上显示的文字：当前选中的中文名；读不到就照实说，不编假数据。
    private func refreshAgentNote() {
        let cur = AgentStore.of(brainCharId)
        if let hit = agentItems.first(where: { $0.id == cur }) {
            agentNote = hit.name
        } else {
            agentNote = cur == AgentStore.default ? "默认的" : cur
        }
    }

    /// 点行：先把台子上的真实列表拉下来，再弹面板。拉不到就提示重试。
    private func 打开脑子列表() {
        Task {
            do {
                let items = try await AgentStore.list()
                await MainActor.run {
                    agentItems = items
                    refreshAgentNote()
                    showAgent = true
                }
            } catch {
                await MainActor.run { agentNote = "没读到，点这行再试" }
            }
        }
    }

    /// 单选项 + 说明。选中：本地记住 → 行上立刻更新 → 后台存台子。
    private var agentSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("「\(brainCharId == CatBrain.builtinId ? "自带的那只" : brainCharId)」用哪个脑子想")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Cfg.Palette.ink)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            List {
                ForEach(agentItems) { it in
                    Button {
                        AgentStore.set(it.id, for: brainCharId)
                        refreshAgentNote()
                        showAgent = false
                        Task { await AgentStore.saveToCloud(it.id, for: brainCharId) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(it.name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Cfg.Palette.ink)
                                if let d = it.intro, !d.isEmpty {
                                    Text(d)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Cfg.Palette.faint)
                                }
                            }
                            Spacer()
                            if AgentStore.of(brainCharId) == it.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Cfg.Palette.ink)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    Button("用默认的") {
                        AgentStore.set(AgentStore.default, for: brainCharId)
                        refreshAgentNote()
                        showAgent = false
                        Task { await AgentStore.saveToCloud(AgentStore.default, for: brainCharId) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .background(Cfg.Palette.bg)
    }

    // MARK: - 行

    private func row(_ title: String, _ value: String, tappable: Bool = false,
                     tap: @escaping () -> Void = {}) -> some View {
        Button {
            if tappable {
                tap()
            }
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Cfg.Palette.ink)
                Spacer()
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(Cfg.Palette.faint)
                if tappable {
                    Text("  ›")
                        .font(.system(size: 13))
                        .foregroundStyle(Cfg.Palette.faint)
                }
            }
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(Cfg.Palette.line.opacity(0.18))
            .frame(height: 0.8)
    }

    /// 聊天钱包那一行：三个数都从接口来，缺一个整行就不画。
    private func walletRow(_ w: String) -> some View {
        HStack(alignment: .top) {
            Text("花费")
                .font(.system(size: 15))
                .foregroundStyle(Cfg.Palette.ink)
            Spacer()
            Text(w)
                .font(.system(size: 12))
                .foregroundStyle(Cfg.Palette.faint)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 16)
    }

    // MARK: - 数据

    private var accountText: String {
        if let me = auth.me, !me.phone.isEmpty {
            return maskPhone(me.phone)
        }
        return "还没登录"
    }

    private var brainText: String {
        brainKey.isEmpty ? "没填" : CatBrain.providerLabel(brainKey)
    }

    private func refreshBrainNote() {
        brainNote = brainKey.isEmpty
            ? "没填钥匙时，它会走台子上的那把 —— 断网就只会说固定那几句。"
            : "存好了 · 这只猫现在用它自己的钥匙（\(CatBrain.providerLabel(brainKey))）"
    }

    private func maskPhone(_ p: String) -> String {
        guard p.count >= 7 else { return p }
        let head = p.prefix(3)
        let tail = p.suffix(4)
        return "\(head)****\(tail)"
    }

    // MARK: - 连接大脑

    private var brainSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("给它一把自己的钥匙")
                    .font(.system(size: 17, weight: .bold))
                Text("填了就用你的（智谱 GLM-4-Flash 免费 / DeepSeek）；不填就走台子上的那把。")
                    .font(.system(size: 12))
                    .foregroundStyle(Cfg.Palette.faint)

                TextField("粘贴 Key", text: $brainKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Tw.gray100)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    CatBrain.setKey(brainKey, for: brainCharId)
                    refreshBrainNote()
                    showBrain = false
                } label: {
                    Text("存好")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Tw.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if !brainNote.isEmpty {
                    Text(brainNote)
                        .font(.system(size: 11))
                        .foregroundStyle(Cfg.Palette.faint)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("大脑")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
