import SwiftUI

// ★ 2026-11-23 二次修正：真辉光 —— 从白卡边缘「向外晕开」，不是描一圈线。
// 做法：在白卡底下垫两层冷色圆角并做 .blur()，白卡盖住光心，
// 只留边缘透出来的柔光；最外面再垫一层黑影托住，浅卡就像浮在深底上。
private struct 冷光悬浮: ViewModifier {
    var 圆角: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // 远光：冷青 rgba(111,168,184)，大半径慢慢散开
                    RoundedRectangle(cornerRadius: 圆角)
                        .fill(Color(red: 111/255, green: 168/255, blue: 184/255).opacity(0.55))
                        .blur(radius: 20)
                    // 近光：冷蓝白 rgba(143,180,255)，小半径、亮一点，贴边往外透
                    RoundedRectangle(cornerRadius: 圆角)
                        .fill(Color(red: 143/255, green: 180/255, blue: 255/255).opacity(0.75))
                        .blur(radius: 8)
                }
            )
            // 基础黑影托底
            .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
    }
}
private extension View {
    func 上冷光(_ 圆角: CGFloat = 16) -> some View {
        modifier(冷光悬浮(圆角: 圆角))
    }
}

// MARK: - 记忆页（原生版，2026-11-23）
//
// 整页不再嵌网页：深色底 + 柔光、原生粒子球、原生半圆轮盘、原生卡片。
// 交互与网页版一一对应：点球上一颗 → 转到正面 + 拉线 + 出信息卡；
// 点「打开这一份」→ 大卡片列表/详情，可改可删可加；三个点 → 角色表。
//
// ★ 数据只走 MemAPI 真读真写；读不到就空球 + 一句人话，绝不编数据。
// ★ 旧的网页版 Mem3DView 原样留着，要退回把 MainHomeView 那一行换回去即可。

struct MemPageNative: View {
    let charId0: String

    @Environment(\.dismiss) private var dismiss

    @State private var 角色: [MemAPI.Role] = []
    @State private var curId: String = ""
    @State private var 节点: [MemNode] = []
    @State private var 聚焦: MemNode?
    /// 点一颗：先长线（0→1），线到位浮窗才长出来；关卡片时给球发清焦点信号
    @State private var 线进度: CGFloat = 0
    @State private var 浮窗长好 = false
    @State private var 清焦点号 = 0

    @State private var 搜索 = ""
    @State private var 大卡路径: [MemNode] = []
    @State private var 大卡详情正文: String = ""
    @State private var 大卡说明: String = ""

    @State private var 角色表开 = false
    @State private var 角色表搜 = ""
    @State private var 加卡开 = false
    @State private var 加卡页 = 0
    @State private var 新正文 = ""
    @State private var 新说明 = ""
    @State private var 新文件名 = ""

    @State private var 待删: MemNode?
    @State private var 吐 = ""
    @State private var 载入中 = true
    @State private var 拉柜子中 = false
    @State private var 光晕动 = false

    private let 深底 = Color(red: 14/255, green: 16/255, blue: 24/255)

    // MARK: 画面

    var body: some View {
        GeometryReader { geo in
            ZStack {
                背景

                MemPlanet(nodes: 节点, onTap: { nd in
                    if let nd {
                        线进度 = 0
                        浮窗长好 = false
                        聚焦 = nd
                        withAnimation(.easeOut(duration: 0.28)) { 线进度 = 1 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                            if 聚焦?.id == nd.id {
                                withAnimation(.easeOut(duration: 0.22)) { 浮窗长好 = true }
                            }
                        }
                    } else {
                        关聚焦()
                    }
                }, 线进度: 线进度, 线终点Y: geo.size.height * 0.45, 清焦点号: 清焦点号)
                // ★ 2026-11-24：球往屏幕中间挪——底距从 196 收到 128。
                .padding(.bottom, 128)

                VStack(spacing: 0) {
                    顶栏
                    if !搜索.isEmpty { 搜索结果 }
                    Spacer(minLength: 0)
                }

                // ★ 轮盘和球同一块区域、同一球心：头像沿球上半弧，名字内圈一一对应。
                MemRoleWheel(角色: $角色, cur: Binding(
                    get: { 当前索引 },
                    set: { 切角色到($0) }
                )) { 角色表开 = true }
                .padding(.bottom, 128)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let f = 聚焦, 浮窗长好 {
                    信息卡层(f, geo)
                }

                弹层
                吐司层
            }
            .background(深底.ignoresSafeArea())
            .onAppear {
                开始动()
                Task { await 起() }
            }
        }
    }

    // 背景：深底 + 三团缓慢游走的柔光
    private var 背景: some View {
        ZStack {
            深底
            Circle()
                .fill(RadialGradient(colors: [Color(red: 72/255, green: 104/255, blue: 196/255).opacity(0.28), .clear],
                                     center: .center, startRadius: 0, endRadius: 260))
                .frame(width: 520, height: 520)
                .blur(radius: 60)
                .offset(x: 光晕动 ? 40 : -40, y: 光晕动 ? -60 : -20)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 150/255, green: 86/255, blue: 168/255).opacity(0.24), .clear],
                                     center: .center, startRadius: 0, endRadius: 240))
                .frame(width: 480, height: 480)
                .blur(radius: 60)
                .offset(x: 光晕动 ? -50 : 50, y: 光晕动 ? 160 : 190)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 46/255, green: 140/255, blue: 150/255).opacity(0.18), .clear],
                                     center: .center, startRadius: 0, endRadius: 220))
                .frame(width: 440, height: 440)
                .blur(radius: 60)
                .offset(x: 光晕动 ? 60 : -20, y: 光晕动 ? 320 : 360)
        }
        .ignoresSafeArea()
    }

    private func 开始动() {
        withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
            光晕动 = true
        }
    }

    // MARK: 顶栏

    private var 顶栏: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(red: 0.9, green: 0.91, blue: 0.95))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                TextField("", text: $搜索,
                          prompt: Text("搜一搜，直接打开任意一层")
                            .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61)))
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                if !搜索.isEmpty {
                    Button { 搜索 = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(.white, in: Capsule())
            .上冷光(20)

            Button { 开加卡() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .frame(width: 42, height: 40)
                    .background(.white, in: Capsule())
                    .上冷光(20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
    }

    private var 搜索结果: some View {
        let hits = 搜到的()
        return VStack(spacing: 0) {
            if hits.isEmpty {
                Text("没找到「\(搜索)」")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ForEach(hits, id: \.id) { n in
                    Button {
                        搜索 = ""
                        开大卡(n)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(类别色(n.cat)).frame(width: 7, height: 7)
                            Text(n.label).font(.system(size: 11))
                                .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                            Spacer()
                            Text(n.type == "folder" ? "球上" : n.catName)
                                .font(.system(size: 8.5))
                                .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color(red: 0.91, green: 0.91, blue: 0.89))
                }
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .padding(.horizontal, 15)
        .padding(.top, 4)
    }

    // MARK: 信息卡

    private func 信息卡层(_ f: MemNode, _ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: geo.size.height * 0.45)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(类别色(f.cat)).frame(width: 8, height: 8)
                    Text(f.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(标签名(f))
                        .font(.system(size: 8.5))
                        .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                }
                Text(f.说明.isEmpty ? (f.desc.isEmpty ? "还没有写说明。" : f.desc) : f.说明)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                    .lineSpacing(2)
                    .padding(.leading, 15)
                    .padding(.top, 7)
                    .padding(.bottom, 10)

                Button { 开大卡(f) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                        Text("打开这一份").font(.system(size: 10.5))
                    }
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Color(red: 0.97, green: 0.97, blue: 0.96),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(13)
            .frame(width: 248)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .上冷光(16)
            Spacer()
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.86, anchor: .top)), removal: .opacity))
    }

    // MARK: 所有弹层

    @ViewBuilder private var 弹层: some View {
        if !大卡路径.isEmpty {
            遮罩层
            大卡层
        }
        if 角色表开 {
            遮罩层
            角色表层
        }
        if 加卡开 {
            遮罩层
            加卡层
        }
        if 待删 != nil {
            遮罩层
            确认层
        }
    }

    private var 遮罩层: some View {
        Color.black.opacity(0.58)
            .ignoresSafeArea()
            .onTapGesture { 关所有() }
            .transition(.opacity)
    }

    // ---------------- 大卡 ----------------

    private var 当前文件: MemNode? { 大卡路径.last }

    private var 大卡层: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { 大卡返回() } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                        .frame(width: 31, height: 31)
                        .background(.white, in: Circle())
                        .overlay(Circle().stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Text(当前文件?.label ?? "")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .lineLimit(1)
                Spacer()
                if (当前文件?.type ?? "") == "folder" {
                    Button { 开加卡() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                            .frame(width: 31, height: 31)
                            .background(.white, in: Circle())
                            .overlay(Circle().stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(13)
            Divider().overlay(Color(red: 0.91, green: 0.91, blue: 0.89))
            ScrollView { 大卡内容.padding(13) }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .上冷光(20)
        .padding(.horizontal, 14)
        .padding(.top, 56)
        .padding(.bottom, 104)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    @ViewBuilder private var 大卡内容: some View {
        if let f = 当前文件, f.type == "folder" {
            Text("点一条看详情 · 长按左边小图标删掉 · 右上 + 在这一层加")
                .font(.system(size: 9.5))
                .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 9)
            if (f.kids ?? []).isEmpty {
                Text("这一层还空着，点右上 + 加一份。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                ForEach(f.kids ?? []) { k in
                    列表行(k)
                }
            }
        } else if let f = 当前文件 {
            详情(f)
        }
    }

    private func 列表行(_ k: MemNode) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.95, green: 0.95, blue: 0.94))
                Text("●").font(.system(size: 13)).foregroundColor(类别色(k.cat))
            }
            .frame(width: 36, height: 36)
            .onLongPressGesture(minimumDuration: 0.55) {
                待删 = k
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(k.label).font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07)).lineLimit(1)
                Text(k.desc.isEmpty ? "点开看看里面" : k.desc)
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
        }
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { 进一层(k) }
    }

    private func 详情(_ f: MemNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if f.type == "act" { 动作预览(charId: curId, 动作名: f.label) }
            Text("上面是记的原物；下面写清它为什么被记下来")
                .font(.system(size: 9.5))
                .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                .padding(.bottom, 9)

            TextEditor(text: $大卡详情正文)
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))

            Text("为什么记它")
                .font(.system(size: 9.5))
                .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                .padding(.top, 12).padding(.bottom, 5)

            TextField("什么时候说的 / 为什么说 / 记下来有什么用", text: $大卡说明)
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))

            Button { 存(f) } label: {
                Text("存好")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Color(red: 0.07, green: 0.07, blue: 0.07),
                                in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    // ---------------- 角色表 ----------------

    private var 角色表层: some View {
        VStack(spacing: 0) {
            HStack {
                Text("所有角色")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                Spacer()
                Button { 角色表开 = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 9)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                TextField("", text: $角色表搜, prompt: Text("搜角色名字")
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61)))
                    .font(.system(size: 11))
                .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color(red: 0.97, green: 0.97, blue: 0.96), in: Capsule())
            .padding(.bottom, 5)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(角色.enumerated()), id: \.element.id) { i, r in
                        if 角色表搜.isEmpty || r.名字.lowercased().contains(角色表搜.lowercased()) {
                            HStack(spacing: 10) {
                                ZStack {
                                    Circle().fill(Color(red: 0.89, green: 0.95, blue: 0.97))
                                    Text(String(r.名字.prefix(1)))
                                        .font(.system(size: 15)).foregroundColor(.black.opacity(0.8))
                                }
                                .frame(width: 32, height: 32)
                                Text(r.名字).font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                                Spacer()
                                Text("\(r.n) 份").font(.system(size: 9))
                                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                                ZStack {
                                    Circle()
                                        .fill(i == 当前索引 ? Color(red: 0.07, green: 0.07, blue: 0.07) : .white)
                                        .overlay(Circle().stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                                    if i == 当前索引 {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                    }
                                }
                                .frame(width: 17, height: 17)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                切角色到(i)
                                角色表开 = false
                                提示("现在看「\(r.名字)」")
                            }
                            Divider().overlay(Color(red: 0.91, green: 0.91, blue: 0.89))
                        }
                    }
                    if 角色.isEmpty {
                        Text("还没读到角色")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                            .padding(.vertical, 14)
                    }
                }
            }
        }
        .padding(15)
        .frame(maxHeight: UIScreen.main.bounds.height * 0.60, alignment: .top)
        .background(.white, in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .transition(.move(edge: .bottom))
    }

    // ---------------- 加记忆 ----------------

    private var 加卡层: some View {
        VStack(alignment: .leading, spacing: 0) {
            if 加卡页 == 0 {
                Text("＋")
                    .font(.system(size: 30))
                    .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                    .frame(width: 84, height: 84)
                    .background(Color(red: 0.95, green: 0.95, blue: 0.94), in: Circle())
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                Text(当前角色名)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .frame(maxWidth: .infinity)

                VStack(spacing: 0) {
                    选项行("T", "文字", "写一段话，它读一遍记住") { 加卡页 = 1 }
                    Divider().overlay(Color(red: 0.91, green: 0.91, blue: 0.89))
                    选项行("▤", "文件", "照片、文件，记一笔") { 加卡页 = 2 }
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                .padding(.top, 12)

                Button { 关加卡() } label: {
                    Text("关上").font(.system(size: 11))
                        .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            } else if 加卡页 == 1 {
                Text("文字").font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .padding(.bottom, 10)
                TextEditor(text: $新正文)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                TextField("", text: $新说明, prompt: Text("为什么记它：什么时候 / 为什么说 / 有什么用")
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61)))
                    .font(.system(size: 11.5))
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                    .padding(.top, 9)
                脚("确认") { 存新的文字() }
            } else {
                Text("文件").font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    .padding(.bottom, 10)
                TextField("", text: $新文件名, prompt: Text("文件名 / 一句话")
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61)))
                    .font(.system(size: 12))
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                Text("原文件仍在手机里，柜子只记一条。")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                    .padding(.top, 8)
                脚("确认") { 存新的文件() }
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private func 选项行(_ icon: String, _ title: String, _ sub: String,
                     _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 11) {
                Text(icon)
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                    .frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
                    Text(sub).font(.system(size: 9))
                        .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.64, green: 0.64, blue: 0.61))
            }
            .padding(11)
        }
        .buttonStyle(.plain)
    }

    private func 脚(_ ok: String, _ tap: @escaping () -> Void) -> some View {
        HStack {
            Button { 关加卡() } label: {
                Text("关上").font(.system(size: 11))
                    .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: tap) {
                Text(ok)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Color(red: 0.07, green: 0.07, blue: 0.07),
                                in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 11)
    }

    // ---------------- 删除确认 ----------------

    private var 确认层: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("确定删掉这一份？")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(red: 0.07, green: 0.07, blue: 0.07))
            Text("「\(待删?.label ?? "这一份")」会从柜子里删掉，可以在返回里找回来。")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                .padding(.top, 6)
            HStack(spacing: 7) {
                Button { 待删 = nil } label: {
                    Text("再想想").font(.system(size: 11))
                        .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(red: 0.91, green: 0.91, blue: 0.89), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { 真删() } label: {
                    Text("删掉").font(.system(size: 11))
                        .foregroundColor(Color(red: 0.75, green: 0.22, blue: 0.17))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(Color(red: 1, green: 0.95, blue: 0.95),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 28)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    // ---------------- 吐司 ----------------

    @ViewBuilder private var 吐司层: some View {
        if !吐.isEmpty {
            VStack {
                Spacer()
                Text(吐)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(Color(red: 0.07, green: 0.07, blue: 0.07), in: Capsule())
                    .padding(.bottom, 76)
            }
            .transition(.opacity)
        }
    }

    // MARK: - 数据

    private var 当前索引: Int {
        角色.firstIndex(where: { $0.标识 == curId }) ?? 0
    }
    private var 当前角色名: String {
        角色.first(where: { $0.标识 == curId })?.名字 ?? "它"
    }

    private func 起() async {
        if curId.isEmpty { curId = charId0 }
        let rs = await MemAPI.角色列表()
        await MainActor.run {
            if rs.isEmpty {
                if 角色.isEmpty {
                    角色 = [MemAPI.Role(标识: curId, 名字: "它", n: 0)]
                }
            } else {
                角色 = rs
                if !rs.contains(where: { $0.标识 == curId }) {
                    curId = rs[0].标识
                }
            }
            载入中 = false
        }
        await 拉柜子(curId)
    }

    private func 拉柜子(_ cid: String) async {
        if 拉柜子中 { return }
        拉柜子中 = true
        let box = await MemAPI.列(cid, nil)
        var list: [MemNode] = []
        var uid = 1
        for cat in MemAPI.类别 {
            let fs = box[cat] ?? []
            var kids: [MemNode] = []
            for f in fs {
                kids.append(MemNode(id: uid, label: f.名,
                                    type: cat == "它会的动作" ? "act" : "text",
                                    cat: cat == "它会的动作" ? "act" : "text",
                                    catName: cat, desc: f.摘要, 说明: f.说明))
                uid += 1
            }
            list.append(MemNode(id: uid, label: cat, type: "folder", cat: "folder",
                                catName: cat, desc: "\(fs.count) 份", kids: kids))
            uid += 1
        }
        await MainActor.run {
            节点 = list
            拉柜子中 = false
        }
    }

    private func 切角色到(_ i: Int) {
        guard i >= 0, i < 角色.count else { return }
        let id = 角色[i].标识
        guard id != curId else { return }
        curId = id
        关聚焦()
        节点 = []
        Task { await 拉柜子(id) }
    }

    private func 开大卡(_ n: MemNode) {
        // 顶层节点（四类文件夹）直接开；子项要带上它的父层，返回才退得回去
        if n.type == "folder" {
            大卡路径 = [n]
        } else if let parent = 节点.first(where: { ($0.kids ?? []).contains(where: { $0.id == n.id }) }) {
            大卡路径 = [parent, n]
        } else {
            大卡路径 = [n]
        }
        大卡详情正文 = ""
        大卡说明 = n.说明.isEmpty ? n.desc : n.说明
        关聚焦()
        if n.type != "folder" { Task { await 读正文(n) } }
    }

    private func 大卡返回() {
        if !大卡路径.isEmpty { 大卡路径.removeLast() }
    }

    private func 进一层(_ k: MemNode) {
        大卡路径.append(k)
        if k.type != "folder" {
            大卡详情正文 = ""
            大卡说明 = k.说明.isEmpty ? k.desc : k.说明
            Task { await 读正文(k) }
        }
    }

    private func 读正文(_ n: MemNode) async {
        if let d = await MemAPI.读(curId, n.catName, n.label) {
            await MainActor.run {
                大卡详情正文 = d.正文
                if 大卡说明.isEmpty { 大卡说明 = d.元信息["注解"] ?? "" }
            }
        }
    }

    private func 存(_ n: MemNode) {
        Task {
            let ok = await MemAPI.动("/api/mem/edit", curId, [
                "类别": n.catName, "名": n.label, "正文": 大卡详情正文,
                "注解": 大卡说明,
            ])
            await MainActor.run {
                提示(ok ? "存好了" : "没存上，检查一下网络")
                if ok { Task { await 拉柜子(curId) } }
            }
        }
    }

    private func 真删() {
        guard let n = 待删 else { return }
        待删 = nil
        Task {
            let ok = await MemAPI.动("/api/mem/delete", curId, ["类别": n.catName, "名": n.label])
            await MainActor.run {
                提示(ok ? "删掉了" : "没删掉，检查一下网络")
                if ok {
                    Task { await 拉柜子(curId) }
                    if 大卡路径.last?.id == n.id { 大卡路径.removeLast() }
                }
            }
        }
    }

    private func 存新的文字() {
        let body = 新正文.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { 提示("先写点什么"); return }
        let title = String(body.replacingOccurrences(of: "\n", with: " ").prefix(10))
        let desc = 新说明.trimmingCharacters(in: .whitespacesAndNewlines)
        写一份(title, desc, body)
    }

    private func 存新的文件() {
        let name = 新文件名.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { 提示("先写个名字"); return }
        写一份(name, "这是一份文件：上面留着它的名字，真正的内容在文件本身。", "【文件】" + name)
    }

    private func 写一份(_ name: String, _ desc: String, _ body: String) {
        Task {
            let ok = await MemAPI.动("/api/mem/write", curId, [
                "类别": "它记住的", "名": name, "正文": body, "注解": desc,
            ])
            await MainActor.run {
                关加卡()
                新正文 = ""; 新说明 = ""; 新文件名 = ""
                提示(ok ? "确认了，也让它读进去了" : "没写进去，检查一下网络")
                if ok { Task { await 拉柜子(curId) } }
            }
        }
    }

    // MARK: - 小工具

    private func 关聚焦() {
        线进度 = 0
        浮窗长好 = false
        清焦点号 += 1
        withAnimation(.easeOut(duration: 0.15)) { 聚焦 = nil }
    }

    private func 开加卡() {
        加卡页 = 0
        新正文 = ""; 新说明 = ""; 新文件名 = ""
        withAnimation(.easeOut(duration: 0.2)) { 加卡开 = true }
        关聚焦()
    }

    private func 关加卡() {
        withAnimation(.easeOut(duration: 0.16)) { 加卡开 = false }
    }

    private func 关所有() {
        withAnimation(.easeOut(duration: 0.18)) {
            大卡路径 = []
            角色表开 = false
            加卡开 = false
            待删 = nil
        }
    }

    private func 提示(_ s: String) {
        withAnimation(.easeOut(duration: 0.16)) { 吐 = s }
        Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            await MainActor.run {
                if 吐 == s { withAnimation(.easeOut(duration: 0.22)) { 吐 = "" } }
            }
        }
    }

    private func 搜到的() -> [MemNode] {
        var out: [MemNode] = []
        let v = 搜索.lowercased()
        for n in 节点 {
            if n.label.lowercased().contains(v) || n.desc.lowercased().contains(v) {
                out.append(n)
            }
            for k in (n.kids ?? []) {
                if k.label.lowercased().contains(v) || k.desc.lowercased().contains(v) {
                    out.append(k)
                }
                if out.count >= 6 { return out }
            }
            if out.count >= 6 { break }
        }
        return out
    }

    private func 标签名(_ n: MemNode) -> String {
        switch n.type {
        case "folder": return "文件夹"
        case "text": return "文字"
        case "act": return "动作"
        default: return "文件"
        }
    }

    private func 类别色(_ cat: String) -> Color {
        switch cat {
        case "act": return Color(red: 0.07, green: 0.07, blue: 0.07)
        case "image", "video": return Color(red: 91/255, green: 143/255, blue: 168/255)
        default: return Color(red: 0.43, green: 0.43, blue: 0.41)
        }
    }
}

// MARK: - 半圆轮盘（原生）

/// 轮盘上一颗头像的位置。
private struct 轮盘项: Identifiable {
    let id: Int
    let x: CGFloat   // 头像外圈
    let y: CGFloat
    let nx: CGFloat  // 名字内圈
    let ny: CGFloat
    let deg: CGFloat // 当前角度（算边缘虚化）
}

struct MemRoleWheel: View {
    @Binding var 角色: [MemAPI.Role]
    @Binding var cur: Int
    var onHub: () -> Void

    @State private var wd: CGFloat = 0

    // ★ 2026-11-24：轮盘和球同一块区域、同一球心。头像贴球的上半外缘，名字在内圈一一对应。
    private func 球半径(_ W: CGFloat) -> CGFloat { min(W * 0.31, 112) }
    private func 头像弧半径(_ W: CGFloat) -> CGFloat { 球半径(W) + 12 }
    private func 名字弧半径(_ W: CGFloat) -> CGFloat { 球半径(W) - 26 }
    private func 球心Y(_ H: CGFloat) -> CGFloat { H / 2 - 6 }
    private func hubY(_ W: CGFloat, _ H: CGFloat) -> CGFloat { 球心Y(H) + 球半径(W) + 26 }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let cx = W / 2
            let cy = 球心Y(H)
            let R = 头像弧半径(W)
            let Rn = 名字弧半径(W)
            let items = 可见(W: W, H: H)

            ZStack {
                ForEach(items) { item in
                    let i = item.id
                    let sel = (i == cur)
                    // 边缘虚化：离中心越远，越小、越淡、越糊
                    let t = min(1, abs(item.deg - 90) / 68)
                    let fade = 1 - 0.78 * t
                    let d: CGFloat = (sel ? 50 : 44) * (1 - 0.26 * t)

                    // 名字（内圈）——与头像同角度一一对应
                    Text(角色[i].名字)
                        .font(.system(size: (sel ? 11 : 10) * (1 - 0.18 * t), weight: sel ? .bold : .regular))
                        .foregroundColor(sel ? .white : Color.white.opacity(0.86))
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(fade)
                        .blur(radius: 1.4 * t)
                        .position(x: item.nx, y: item.ny)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard i != cur else { return }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            cur = i; wd = 0
                        }

                    // 头像（外圈，贴球上半缘）
                    ZStack {
                        Circle().fill(Color(red: 143/255, green: 180/255, blue: 255/255).opacity(sel ? 0.7 : 0.34))
                            .blur(radius: sel ? 10 : 7)
                        Circle().fill(Color(red: 111/255, green: 168/255, blue: 184/255).opacity(sel ? 0.5 : 0.24))
                            .blur(radius: sel ? 20 : 14)
                        Circle().fill(Color(red: 0.06, green: 0.07, blue: 0.11))
                        OrbPet(charId: 角色[i].标识, actName: "sit", width: d * 0.82)
                            .frame(width: d * 0.82, height: d * 0.82)
                            .clipShape(Circle())
                        Circle()
                            .stroke(sel ? Color(red: 0.56, green: 0.71, blue: 1) : .white.opacity(0.25),
                                    lineWidth: sel ? 2 : 1)
                    }
                    .frame(width: d, height: d)
                    .opacity(fade)
                    .blur(radius: 1.1 * t)
                    .position(x: item.x, y: item.y)
                    .contentShape(Circle())
                    .onTapGesture {
                        guard i != cur else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        cur = i; wd = 0
                    }
                }

                // 中心三个点钮：放在球的下缘外，不挡球
                ZStack {
                    Circle().fill(Color(red: 143/255, green: 180/255, blue: 255/255).opacity(0.65))
                        .blur(radius: 9)
                    Circle().fill(Color(red: 111/255, green: 168/255, blue: 184/255).opacity(0.45))
                        .blur(radius: 18)
                    Circle().fill(.white)
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Color(red: 0.07, green: 0.07, blue: 0.07))
                                .frame(width: 4, height: 4)
                        }
                    }
                }
                .frame(width: 40, height: 40)
                .position(x: cx, y: hubY(W, H))
                .onTapGesture { onHub() }
            }
            // ★ 只在"上半弧带"吃拖动，球心与球下半留给球转/点节点。
            .contentShape(Path { p in
                p.addArc(center: CGPoint(x: cx, y: cy), radius: R,
                         startAngle: .degrees(160), endAngle: .degrees(20), clockwise: true)
                p.addArc(center: CGPoint(x: cx, y: cy), radius: Rn,
                         startAngle: .degrees(20), endAngle: .degrees(160), clockwise: true)
                p.closeSubpath()
            })
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { g in
                        wd = g.translation.width * 0.34
                    }
                    .onEnded { _ in
                        var s = Int((wd / 46).rounded())
                        if abs(wd) < 23 { s = 0 }
                        let n = 角色.count
                        if s != 0 && n > 0 {
                            cur = ((cur + s) % n + n) % n
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { wd = 0 }
                    }
            )
        }
    }

    /// 看得见的那几颗（按离中间远近排序，远的先画）。x/y=头像外圈，nx/ny=名字内圈。
    private func 可见(W: CGFloat, H: CGFloat) -> [轮盘项] {
        var out: [轮盘项] = []
        let n = 角色.count
        guard n > 0 else { return out }
        let R = 头像弧半径(W)
        let Rn = 名字弧半径(W)
        let cx = W / 2
        let cy = 球心Y(H)
        var arr: [(Int, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = []
        for i in 0..<n {
            var d = i - cur
            while d > n / 2 { d -= n }
            while d < -n / 2 { d += n }
            let deg = 90 + CGFloat(d) * 46 - wd
            if deg < 22 || deg > 158 { continue }
            let rad = deg * .pi / 180
            // 第 5 项=带符号档数（排序用绝对值、虚化用真实角度），第 6 项=真实角度
            arr.append((i, cx + R * cos(rad), cy - R * sin(rad),
                        cx + Rn * cos(rad), cy - Rn * sin(rad), abs(CGFloat(d)), deg))
        }
        arr.sort { $0.5 > $1.5 }
        for a in arr { out.append(轮盘项(id: a.0, x: a.1, y: a.2, nx: a.3, ny: a.4, deg: a.6)) }
        return out
    }
}

/// 动作卡上方那块：真帧在动；没装包就直说没装，绝不画一张假图冒充。
private struct 动作预览: View {
    let charId: String
    let 动作名: String
    @State private var 帧 = 0
    @State private var 包: CatPack?
    @State private var 定时器: Timer?

    private var 本条: CatPack.Act? { 包?.acts.first(where: { $0.name == 动作名 }) }

    var body: some View {
        ZStack {
            Color(red: 0.97, green: 0.97, blue: 0.96)
            if let p = 包, let a = 本条, let img = p.image(act: a, index: 帧) {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .padding(.vertical, 4)
            } else {
                Text("这台手机上还没装这条动作的画面，先看下面写的是什么")
                    .font(.system(size: 10))
                    .foregroundColor(Color(red: 0.43, green: 0.43, blue: 0.41))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            包 = CatPackStore.shared.installed(charId)
            let 间隔 = 1.0 / max(8, min(24, 本条?.fps ?? 12))
            定时器 = Timer.scheduledTimer(withTimeInterval: 间隔, repeats: true) { _ in
                let n = 本条?.frames ?? 0
                帧 = n > 0 ? (帧 + 1) % n : 0
            }
        }
        .onDisappear {
            定时器?.invalidate()
            定时器 = nil
        }
    }
}
