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
    /// ★ 2026-10-23（他第三次说层级）：从**角色列表**点进来先看「大框」——
    ///   大框里是它的坐立动图，**点这个大框才进动作库**。
    var home: Bool = false
    /// 「去把剩下的动作做出来」 —— 完成页 / 动作库里那颗键
    var onStudio: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var names: Set<String> = []
    @State private var loading = true
    @State private var err = ""
    @State private var repairing = false
    @State private var repairNote = ""
    @State private var showAdd = false
    @State private var watching: String?
    /// 一条动作都没有时那两句 —— 「还没开始做」／「前面还有几条在做」
    @State private var queueLine = ""
    /// ★★★ 2026-10-23（「下单回执」）：这一只**已经有一趟在跑/在排**的话，正在做的动作名。
    ///   他说过不止一次：「我点了接着做，退出去就像没点过，只能再下一单」。
    ///   所以这一页只要它在做，就必须把「已经下了这一单」挂在明面上。
    @State private var inFlight: [String] = []

    private var has: [(key: String, label: String)] {
        ActLab.official.filter { names.contains($0.key) }
    }

    /// 完成页 → 动作库。★ 用一个本地开关翻过去，不重新开页（重开页会把上面那只重置一下）。
    @State private var leftShowcase = false
    private var isShowcase: Bool { showcase && !leftShowcase }
    /// 「这一只」那一屏（大框）—— 点过框就翻成动作库
    private var isHome: Bool { home && !leftShowcase }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isHome {
                        homeCard
                    } else {
                        if isShowcase { showcaseCard } else { topBox }
                    }
                    // ★ 自救口常驻 —— 大框那一屏也得有（他从来找不到藏在二级页里的东西）
                    repairBar
                    if !err.isEmpty {
                        Text(err)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Tw.red600)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !isHome {
                        grid
                        if names.isEmpty { emptyState }
                        if missingActs > 0 { continueCard }
                    }
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
                Text((isHome || isShowcase) ? char.title : "动作库")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text(isHome ? "点下面那个框，看它会做的所有动作"
                     : (isShowcase ? "它已经住进你手机了" : "\(char.title) · \(names.count) 条动作"))
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

    /// 完成页 / 这一只（大框）→ 动作库
    private func showcaseOff() { leftShowcase = true }

    // MARK: 「这一只」—— 一个大框

    /// ★ 他原话：「角色点进去应该是一个大框，大框是坐立的那个动态动作展示，
    ///   然后点击这个大框才会进入角色的动作库」。
    /// ⇒ 这一屏只有这一个框，点它才翻到动作库。别在这儿塞格子、塞按钮。
    private var homeCard: some View {
        VStack(spacing: 10) {
            Button { showcaseOff() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Tw.gray100)
                    if names.contains("sit") {
                        GifView(url: GifView.makeURL(char.id, "sit", width: 720))
                            .padding(12)
                    } else {
                        VStack(spacing: 9) {
                            Image(systemName: "pawprint.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Tw.gray300)
                            Text("它还没开始做动作\n点这个框进去，就能让它开始")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Tw.gray400)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                        }
                    }
                }
                .frame(height: 360)
            }
            .buttonStyle(PressStyle(scale: 0.98))

            Text("点这个框，看它会做的所有动作")
                .font(.system(size: 12))
                .foregroundStyle(Tw.gray400)

            // ★ 下单回执：已经在做的时候，这一屏也得说出来 ——
            //   他点进角色唯一的目的就是「看看做到哪了」，不是再下一单。
            if !inFlight.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: 0xB45309)).frame(width: 6, height: 6)
                    Text("正在做：\(inFlight.prefix(3).joined(separator: "、"))"
                         + (inFlight.count > 3 ? " 等 \(inFlight.count) 条" : ""))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(hex: 0xB45309))
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 2)
    }

    // MARK: 还有基础动作没做 —— 给他一个接着做的口子

    /// ★ 他问的：「他做完坐立之后其他的基础动作怎么办？只剩下一个添加新动作的窗口了」
    /// ⇒ 11 条没做齐之前，动作库这一页**必须**有这颗键。
    private var missingActs: Int {
        ActLab.official.filter { !names.contains($0.key) }.count
    }

    private var continueCard: some View {
        // ★★★ 2026-10-23（「下单回执」）：这一只**已经在做**的时候，
        //   这颗键不许再写「接着做剩下的 N 个」—— 那是在邀请他再下一单。
        //   他自己的比喻：点了酒、人离桌、回来桌上什么都没有，只能再点一次。
        let busy = !inFlight.isEmpty
        let doing = inFlight.prefix(3).joined(separator: "、")
            + (inFlight.count > 3 ? " 等 \(inFlight.count) 条" : "")
        return Button { onStudio() } label: {
            VStack(spacing: 4) {
                Text(busy ? "看看做到哪了" : "接着做剩下的 \(missingActs) 个")
                    .font(.system(size: busy ? 13.5 : 14.5, weight: .semibold))
                    .foregroundStyle(busy ? Color(hex: 0xB45309) : Tw.white)
                Text(busy ? "已经在做了：\(doing) —— 这一单下过了，不用再点"
                          : "趴下、舔毛、睡觉这些基础动作还没做")
                    .font(.system(size: 10.5))
                    .foregroundStyle(busy ? Color(hex: 0x92400E) : Tw.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(busy ? Color(hex: 0xFFF3E6) : Tw.red600))
        }
        .buttonStyle(PressStyle())
        .padding(.top, 4)
    }

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

    /// 一条都没有的时候：告诉他在等什么（排队／机器忙／还没开始），
    /// 并且给他一颗直接去看的键 —— ★ 他原话：
    /// 「因为他正在排队但用户不知道…这样用户才不会感觉我们的APP坏了或者很慢」。
    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(queueLine.isEmpty ? "这一只还没开始做动作。" : queueLine)
                .font(.system(size: 12.5))
                .foregroundStyle(Tw.gray500)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button { onStudio() } label: {
                Text(queueLine.isEmpty ? "让它开始做" : "去看做到哪了")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Tw.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Tw.red600))
            }
            .buttonStyle(PressStyle())
        }
        .padding(.top, 6)
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
        // 一条都没有 ⇒ 顺手问一句「它现在是在做、还是排在别人后面」
        if names.isEmpty, let g = try? await ActLab.genMine(), let j = g.of(char.id), j.queued == true {
            if j.gateOff == true {
                queueLine = "排上队了 —— 机器这会儿没接活，一开就做"
            } else if (j.ahead ?? 0) > 0 {
                queueLine = "前面还有 \(j.ahead ?? 0) 条在做 —— 轮到它就自动开始"
            } else if j.busy == true {
                queueLine = "机器正忙着别的角色 —— 一空出来就轮到它"
            } else {
                queueLine = "正在做 —— 做好一格就冒出来一格"
            }
        }
        // ★★★ 2026-10-23（下单回执）：不管做没做齐，只要这只猫**有一趟还在跑/在排**，
        //   就把「正在做哪几条」挂出来。退出再进来还在，直到它真的做完。
        inFlight = []
        if let g = try? await ActLab.genMine() {
            for list in [g.当前, g.队列] {
                for j in list ?? [] where j.char == char.id {
                    let doing = (j.acts ?? []).map { label(of: $0) }
                    if !doing.isEmpty { inFlight = doing }
                    else if inFlight.isEmpty { inFlight = ["这一批"] }
                }
            }
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
