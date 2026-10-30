import SwiftUI

// MARK: - 设置页
//
// ★★★ 2026-10-30：对齐安卓 `SettingsV2Activity` —— 安卓现在只有这 5 行：
//     豆包号 / 大脑 / 把这只派给别人 / 按键声 / 关于
//   顺序、文案都照抄。以前 iOS 这些散在 `StatusPanelView` 里（"现在用的号""连接大脑""换一个"），
//   现在收成一张表。

struct SettingsPage: View {
    @EnvironmentObject private var auth: StillAuth
    @Environment(\.dismiss) private var dismiss

    // 大脑的钥匙：跟 StatusPanelView 一样，每只猫一把
    @State private var brainKey = ""
    @State private var brainNote = ""
    @State private var showBrain = false
    @State private var showDispatch = false
    @State private var showTapSheet = false

    private var brainCharId: String { CatBrain.currentCharId }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    row("豆包号", accountText)
                    divider()
                    row("大脑", brainText, tappable: true) { showBrain = true }
                    divider()
                    row("把这只派给别人", "", tappable: true) { showDispatch = true }
                    divider()
                    row("按键声", SoundKit.tapNames[SoundKit.shared.tapKind],
                        tappable: true) { showTapSheet = true }
                    divider()
                    row("关于", AppVersion.tag)
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
        }
        // 连接大脑
        .sheet(isPresented: $showBrain) {
            brainSheet
                .presentationDetents([.medium, .large])
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
                    .background(Color(hex: 0xF2ECE3))
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
                        .background(Cfg.Palette.ink)
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
