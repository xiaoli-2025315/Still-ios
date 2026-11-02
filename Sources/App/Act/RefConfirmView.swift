import SwiftUI
import PhotosUI

// MARK: - ① 参考图确认
//
// ★ 2026-11-01（他定的流程）：登记完之后**加一页**，屏幕中间一张参考图，
//   缓一下浮出一句「就用这张开始做？」，下面一颗「开始生成」。
//   这一页只干这一件事：没有名字输入、没有豆包号、没有别的动作。
//   · 想换图：**直接点那张图**（不另设「换一张」键）
//   · 返回：退回登记页，图还在

struct RefConfirmView: View {

    let name: String
    /// 登记时选的那张图
    @State private var photo: Data
    /// 换图之后要不要重新登记（图变了，台子上那张也得换）
    var onPhotoChanged: (Data) async -> Void
    /// 点「开始生成」
    var onStart: () -> Void
    /// 带渠道的下单（"wan" 或 "doubao:<slot>"）
    var onStartChannel: (String) -> Void
    var onBack: () -> Void

    @State private var pickItem: PhotosPickerItem?
    @State private var showPick = false
    @State private var swapBusy = false
    /// 三段落出现：图 → 问句 → 按钮
    @State private var step = 0
    /// 2026-11-02 防误触：第一次点只是确认，第二次才真的开始
    @State private var awaitConfirm = false

    // ★ 2026-11-03（他定的）：参考图是台子后台做出来的 ——
    //   进来先盖一层「正在做参考图…」（带光带），好了换成处理过的那张；
    //   不满意可以「重新处理」，满意就点「开始生成」（仍然是点两下）。
    let charId: String
    @State private var refImage: UIImage? = nil
    @State private var processing = false
    @State private var refTimedOut = false
    /// 这一格是不是已经下过单（下过就不给再点，避免重复花钱）
    @State private var alreadyOrdered = false
    @State private var alreadyDone = false
    // ★ 2026-11-03（他纠正的）：坐立两条线都能走 —— 这里让他再选一次（防登记页选错）
    @State private var 渠道 = "wan"                 // "wan" 或 "doubao:<slot>"
    @State private var 豆包号: [(String, String, Bool)] = []   // (slot, 名字, 登着)

    init(name: String, photo: Data, charId: String = "",
         onPhotoChanged: @escaping (Data) async -> Void,
         onStart: @escaping () -> Void,
         onStartChannel: @escaping (String) -> Void = { _ in },
         onBack: @escaping () -> Void) {
        self.name = name
        _photo = State(initialValue: photo)
        self.charId = charId
        self.onPhotoChanged = onPhotoChanged
        self.onStart = onStart
        self.onStartChannel = onStartChannel
        self.onBack = onBack
    }

    var body: some View {
        bodyInner.task {
            if !charId.isEmpty { await checkOrdered() }
            await 拉豆包号()
            if !charId.isEmpty && refImage == nil { await watchRef() }
        }
    }

    private var bodyInner: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Tw.gray100))
                }
                .buttonStyle(PressStyle(scale: 0.9))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer(minLength: 12)

            // 参考图（点它就换）
            Button { showPick = true } label: {
                Group {
                    if let ui = (refImage ?? UIImage(data: photo)) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Tw.gray100)
                            .overlay(Text("没有图").foregroundStyle(Tw.gray400))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: UIScreen.main.bounds.height * 0.52)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if processing {
                        ZStack {
                            Color.white.opacity(0.88)
                            VStack(spacing: 12) {
                                LightBandView().padding(.horizontal, 40)
                                Text("正在做参考图…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Tw.gray500)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.horizontal, 24)
                .opacity(step >= 1 ? 1 : 0)
                .offset(y: step >= 1 ? 0 : 10)
            }
            .buttonStyle(PressStyle(scale: 0.98))

            Spacer(minLength: 18)

            // ★ 用哪个做（跟登记页那个下拉一回事）
            Menu {
                Button("wan3.0 · 阿里云") { 渠道 = "wan" }
                ForEach(豆包号, id: \.0) { a in
                    Button("\(a.1) · \(a.2 ? "已登录" : "没登录")") { 渠道 = "doubao:" + a.0 }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("用哪个做").font(.system(size: 12)).foregroundStyle(Tw.gray500)
                    Text(渠道文案).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tw.gray900)
                    Image(systemName: "chevron.down").font(.system(size: 10))
                        .foregroundStyle(Tw.gray400)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Tw.gray50)
                )
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)

            Text("就用这张开始做？")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Tw.gray900)
                .opacity(step >= 2 ? 1 : 0)
                .offset(y: step >= 2 ? 0 : 8)

            Spacer(minLength: 18)

            Button {
                // 二次确认：第一次点变「再点一次就开始」，3 秒内再点才真开始
                if alreadyOrdered || alreadyDone { return }   // 已经下过单，不能再点
                if !awaitConfirm {
                    awaitConfirm = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if awaitConfirm { awaitConfirm = false }
                    }
                    return
                }
                awaitConfirm = false
                // 选的是豆包就把这条渠道带出去（onStart 那边按它下单）
                onStartChannel(渠道)
            } label: {
                HStack(spacing: 8) {
                    if swapBusy { ProgressView().tint(.white) }
                    Text(alreadyDone ? "已经做好了，去看动作库"
                         : (alreadyOrdered ? "已经在做了…"
                            : (awaitConfirm ? "再点一次就开始" : "开始生成")))
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Tw.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Capsule().fill(Tw.gray900))
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .padding(.horizontal, 24)
            .disabled(swapBusy || alreadyOrdered || alreadyDone)
            .opacity(step >= 3 ? 1 : 0)

            if !processing && !charId.isEmpty {
                Button { Task { await rebuild() } } label: {
                    Text("重新处理")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tw.gray600)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Tw.gray300, lineWidth: 1)
                        )
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .padding(.horizontal, 24)
                .padding(.top, 10)
            }
            if refTimedOut {
                Text("参考图还没做好，先用你上传的这张")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
                    .padding(.top, 6)
            }
            Text("点一下那张图可以换一张")
                .font(.system(size: 11))
                .foregroundStyle(Tw.gray400)
                .padding(.top, 10)
                .opacity(step >= 3 ? 1 : 0)

            Spacer(minLength: 24)
        }
        .background(Tw.gray50.ignoresSafeArea())
        .photosPicker(isPresented: $showPick, selection: $pickItem, matching: .images)
        .onChange(of: pickItem) { _, item in
            guard let item else { return }
            Task {
                swapBusy = true
                if let d = try? await item.loadTransferable(type: Data.self) {
                    photo = d
                    await onPhotoChanged(d)     // 台子上那张也换掉
                }
                swapBusy = false
            }
        }
        .onAppear {
            // 缓缓浮出：图 → 问句 → 按钮
            withAnimation(.easeOut(duration: 0.45)) { step = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                withAnimation(.easeOut(duration: 0.45)) { step = 2 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.00) {
                withAnimation(.easeOut(duration: 0.40)) { step = 3 }
            }
        }
    }

    // MARK: - 参考图（处理中 → 换图 → 重新处理）

    private func watchRef() async {
        processing = true
        refTimedOut = false
        for _ in 0..<60 {
            if let ui = await fetchRef() {
                refImage = ui
                processing = false
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        processing = false
        refTimedOut = true
    }

    private func fetchRef() async -> UIImage? {
        guard !charId.isEmpty else { return nil }
        let c = charId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? charId
        guard let url = URL(string: ActLab.base + "/api/wan/ref?char=" + c) else { return nil }
        do {
            let (d, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return UIImage(data: d)
        } catch { return nil }
    }

    private func rebuild() async {
        processing = true
        await ActLab.wanRebuild(charId: charId)
        await watchRef()
    }


    /// 查这一格现在什么状态（没做 / 在做 / 做好）—— 决定按钮能不能点。
    private func checkOrdered() async {
        guard let d = await ActLab.wanState(charId: charId, act: "sit") else { return }
        let st = d.状态 ?? ""
        alreadyOrdered = (st == "生成中" || st == "排队中")
        alreadyDone = (st == "好了")
    }


    private var 渠道文案: String {
        if 渠道 == "wan" { return "wan3.0 · 阿里云" }
        let slot = String(渠道.dropFirst("doubao:".count))
        for a in 豆包号 where a.0 == slot {
            return a.1 + (a.2 ? " · 已登录" : " · 没登录")
        }
        return "豆包" + slot
    }

    /// 台子上记着哪些豆包号（拿不到就只显示 wan3.0，不装作有号）。
    private func 拉豆包号() async {
        guard let d = try? await ActLab.rawGet("/api/login/accounts", timeout: 15),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let o = obj as? [String: Any],
              let arr = o["账号"] as? [[String: Any]] else { return }
        var out: [(String, String, Bool)] = []
        for x in arr {
            let s = (x["slot"] as? String) ?? "1"
            let n = (x["名字"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ("豆包" + s)
            out.append((s, n, (x["登着没"] as? Bool) ?? false))
        }
        豆包号 = out
    }

}
