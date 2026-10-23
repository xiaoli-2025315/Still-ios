import SwiftUI

// MARK: - 一只猫的「完成页」和「动作库」
//
// ★★★ 2026-10-23（他定的新链路）：
//   全部动作做完 ⇒ **完成页**：一只会动的它，点进去是**动作库**。
//   动作库＝顶上一个小动态框 + 下面一格一格，**第一格永远是「添加动作」**。
//   点一格 = 放大看一遍。
//
// ★ 跟安卓 `RoleHomeActivity` 同一个页面，两种样子靠 `showcase` 分：
//   true = 完成页（刚做完，先给他看一眼这只猫）
//   false = 动作库（平时进来翻动作、加动作）
//
// ★★★ 自救口不许藏：顶上那条「一键修复（不花额度）」**常驻**，不管做没做完。
//   他看到猫不动了、格子空了，第一反应就是点这个 —— 绝不能让他去找别的页面。

struct RoleHomeView: View {

    let char: ActLab.Char
    /// true = 刚做完，先给看完成页；false = 直接进动作库
    var showcase: Bool = false
    /// 「去把剩下的动作做出来」 —— 完成页里那颗键
    var onStudio: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var names: Set<String> = []
    @State private var loading = true
    @State private var err = ""
    @State private var repairing = false
    @State private var repairNote = ""
    @State private var showAdd = false
    @State private var watching: String?

    private var has: [(key: String, label: String)] {
        ActLab.official.filter { names.contains($0.key) }
    }

    /// 完成页 → 动作库。★ 用一个本地开关翻过去，不重新开页（重开页会把上面那只重置一下）。
    @State private var leftShowcase = false
    private var isShowcase: Bool { showcase && !leftShowcase }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isShowcase { showcaseCard } else { topBox }
                    repairBar
                    if !err.isEmpty {
                        Text(err)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tw.red600)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    grid
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { await load() }
        .sheet(isPresented: $showAdd) {
            AddActionSheet(char: char) { await load() }
                .presentationDetents([.large])
        }
        .sheet(item: Binding(
            get: { watching.map { Watch(key: $0) } },
            set: { watching = $0?.key }
        )) { w in
            BigPreview(charId: char.id, act: w.key,
                       label: label(of: w.key))
                .presentationDetents([.medium, .large])
        }
    }

    private struct Watch: Identifiable {
        let key: String
        var id: String { key }
    }

    private func label(of key: String) -> String {
        ActLab.official.first { $0.key == key }?.label ?? key
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text(isShowcase ? char.title : "动作库")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(isShowcase ? "它已经住进你手机了" : "\(char.title) · \(names.count) 条动作")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: 完成页 —— 先看这只猫

    private var showcaseCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Tw.gray100)
                GifView(url: GifView.makeURL(char.id, names.contains("sit") ? "sit" : (has.first?.key ?? "sit"),
                                         width: 620))
                    .padding(10)
            }
            .frame(height: 300)

            Text("它在等你")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Tw.gray900)

            Button { showcaseOff() } label: {
                Text("看看它的动作")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tw.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Tw.red600))
            }
            .buttonStyle(PressStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Tw.white))
    }

    /// 完成页 → 动作库
    private func showcaseOff() { leftShowcase = true }

    // MARK: 动作库顶上那个小动态框

    private var topBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Tw.gray100)
            GifView(url: GifView.makeURL(char.id, names.contains("sit") ? "sit" : (has.first?.key ?? "sit"),
                                     width: 480))
                .padding(8)
        }
        .frame(height: 170)
    }

    // MARK: 一键修复（常驻 · 不花额度）

    private var repairBar: some View {
        Button {
            Task { await repair() }
        } label: {
            HStack(spacing: 8) {
                if repairing {
                    ProgressView().scaleEffect(0.75)
                } else {
                    Image(systemName: "bandage")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(repairing ? "正在修，别退出…" : "一键修复（不花额度）")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 0)
                if !repairNote.isEmpty {
                    Text(repairNote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Tw.gray900)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Tw.white))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Tw.gray200, lineWidth: 1)
            )
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .disabled(repairing)
    }

    // MARK: 一格一格

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)],
                  spacing: 10) {
            addCell
            ForEach(has, id: \.key) { a in
                tileCell(a.key, a.label)
            }
        }
    }

    /// ★ 第一格永远是它 —— 他要的「加号在第一个位置」，不用翻到列表底下去找。
    private var addCell: some View {
        Button { showAdd = true } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Tw.gray50)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Tw.gray300,
                                  style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                VStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Tw.gray400)
                    Text("添加动作")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                }
            }
            .aspectRatio(1.35, contentMode: .fit)
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }

    private func tileCell(_ key: String, _ label: String) -> some View {
        Button { watching = key } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tw.gray100)
                GifView(url: GifView.makeURL(char.id, key, width: 260))
                    .padding(6)
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Text(label)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Tw.gray900)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Tw.white.opacity(0.86)))
                        Spacer(minLength: 0)
                    }
                    .padding(7)
                }
            }
            .aspectRatio(1.35, contentMode: .fit)
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }

    // MARK: 干活

    private func load() async {
        loading = true
        do {
            let m = try await ActLab.manifest(charId: char.id)
            names = m.names
            err = ""
        } catch {
            err = "没取到它有哪些动作：" + error.localizedDescription
        }
        loading = false
    }

    private func repair() async {
        repairing = true
        repairNote = ""
        do {
            repairNote = try await ActLab.actRepair(charId: char.id)
            await load()
        } catch {
            repairNote = "没修成：" + error.localizedDescription
        }
        repairing = false
    }
}

// MARK: - 放大看一遍

struct BigPreview: View {

    let charId: String
    let act: String
    let label: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(label)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Spacer(minLength: 0)
                Button("关上") { dismiss() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
            }
            .padding(.top, 14)

            GifView(url: GifView.makeURL(charId, act, width: 900))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("点右上角关上就行")
                .font(.system(size: 10.5))
                .foregroundStyle(Tw.gray400)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 18)
        .background(Tw.gray50.ignoresSafeArea())
    }
}

// MARK: - 添加动作
//
// ★★★ 这里有一件事必须如实说：**台子现在只认词库里那 11 条动作**。
//   随手写一句「抬起爪子扒拉两下」，台子接不了 —— 那要等方舟那把钥匙（他还没实名去拿）。
//   所以：界面按他说的做齐（写描述 + 选模型 + 制作），但点「制作」会**老实说做不了**，
//   并且**把他写的那句留着**，不装作成功、也不清空。
//   我不给他摆一个点了没反应的假按钮。

struct AddActionSheet: View {

    let char: ActLab.Char
    var onAdded: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var desc = ""
    @State private var model = "豆包"
    @State private var told = ""

    private let models = ["豆包", "即梦", "方舟 Seedance"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    Text("想让它做什么")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.bottom, 6)

                    TextEditor(text: $desc)
                        .font(.system(size: 14))
                        .foregroundStyle(Tw.gray900)
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Tw.gray100))
                        .overlay(alignment: .topLeading) {
                            if desc.isEmpty {
                                Text("比如：抬起前爪扒拉两下，然后回头看我")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Tw.gray400)
                                    .padding(.horizontal, 15)
                                    .padding(.top, 18)
                                    .allowsHitTesting(false)
                            }
                        }

                    Text("用哪个模型")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .padding(.top, 20)
                        .padding(.bottom, 6)

                    Picker("用哪个模型", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if !told.isEmpty {
                        Text(told)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tw.gray600)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 16)
                    }

                    Button {
                        Task { await make() }
                    } label: {
                        Text("制作")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tw.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(desc.isEmpty ? Tw.gray300 : Tw.red600))
                    }
                    .disabled(desc.isEmpty)
                    .padding(.top, 22)

                    Text("写一句话就能加一条动作 —— 现在台子只认固定的那 11 条，"
                         + "随手写的还接不了。你写的这句会留着，等能做了直接拿它去做。")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(Tw.gray50.ignoresSafeArea())
            .navigationTitle("添加动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关上") { dismiss() }
                        .foregroundStyle(Tw.gray500)
                }
            }
        }
    }

    private func make() async {
        // ★ 真的做不了，就真的说做不了 —— 描述留着，不清空。
        told = "还做不了：「\(desc)」这句台子现在接不了。"
            + "它只认固定那 11 条动作，任意描述要等方舟那把钥匙。"
            + "\n你写的这句我留在这儿了。"
    }
}
