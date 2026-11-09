import SwiftUI
import UIKit
import Foundation

// MARK: - ② 制作中（照安卓 SitingActivity，2026-11-09 再对齐一次）
//
// ★★★★ 2026-11-09（他定的，两端同一套）：
//  · **只显示三个阶段**：排队 / 正在生成 / 抠图中。
//    「准备中」「生成完毕」「正在装到手机里」这些中间态**不再单独成段**，
//    「等抠图 / 抠像中 / 正在送到手机」全部归进「抠图中」。
//  · **框里有动态背景**，代替以前那条假进度条（唯一真数字是抠像的百分比，按帧数算）。
//  · **「确认下一步」必须等这一条真的装进手机之后才出现** ——
//    台子说「抠好了」≠ 手机里有；必须整猫包真的下完、能读出这一条才放他走。
//  · **不再用「机器在重启/台子停了」这类猜出来的理由报失败。**
//
// 其它规矩（沿用）：
//  · 失败：**原因写在框里**，标题「生成失败」，按钮统一「确认」（点了真回参考图页）
//  · 好了：标题「做好了」，按钮「确认下一步」
//  · 这一页不下单（下单在参考图页）

struct SitingView: View {

    let char: ActLab.Char
    var act: String = "sit"
    var actLabel: String = "坐着张望"
    var onBackToRef: () -> Void = {}
    var onNext: () -> Void = {}

    /// ★ 2026-11-09：三段固定 + 三个收尾态。
    ///   packing 只用于内部判断（要不要等装包），**显示仍然是「抠图中」**。
    private enum Stage: Equatable {
        case queue
        case generating
        case matting(Int)       // 0 = 这条没有真百分比
        case packing            // 抠好了，正在装进手机（显示＝抠图中）
        case done
        case failed(String, Bool)   // 原因, 是不是额度问题
    }

    @State private var stage: Stage = .queue
    @State private var alive = true
    @State private var lastOrder = ""

    /// 这一条真的在本机整猫包里了（＝下载安装到手机完成）
    @State private var 本机有 = false
    @State private var 装包中 = false
    @State private var 上次装包失败 = Date.distantPast
    /// ★ 2026-11-09：装包失败的原因（不再吞掉、停在「抠图中」不吭声）
    @State private var 装包原因 = ""

    private var cellW: CGFloat { UIScreen.main.bounds.width - 40 }

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 0)

            box
                .frame(width: cellW, height: cellW / 1.32)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text(titleText)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isFailed ? Tw.red600 : Tw.gray900)
                if !subText.isEmpty {
                    Text(subText).font(.system(size: 12)).foregroundStyle(Tw.gray400)
                }
                if !lastOrder.isEmpty {
                    Text(lastOrder).font(.system(size: 11)).foregroundStyle(Tw.gray400)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 14)

            Spacer(minLength: 0)

            if let key = keyText {
                Button { tapKey() } label: {
                    Text(key)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(Tw.gray900))
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Tw.white)
        .task { await watch() }
        .onDisappear { alive = false }
    }

    private var header: some View {
        HStack {
            Button { onBackToRef() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 34, height: 34)
            }
            Spacer()
            Text(char.title).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tw.gray900)
            Spacer()
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    // MARK: - 框里的字（三段）

    private var insideMain: String {
        switch stage {
        case .queue: return "排队"
        case .generating: return "正在生成"
        case .matting(let pct): return pct > 0 ? "\(pct)%" : "抠图中"
        case .packing: return "抠图中"
        case .done: return "做好了"
        case .failed(let why, _): return why
        }
    }

    private var insideSub: String {
        switch stage {
        case .queue: return "轮到它就开始"
        case .generating: return "通常 2–4 分钟"
        case .matting(let pct): return pct > 0 ? "正在去背景" : "正在去背景"
        case .packing: return 装包原因.isEmpty ? "片子好了，正在装进你的手机" : "装进手机没成：\(装包原因)（过一会儿会自动再试）"
        case .done: return ""
        case .failed(_, let quota): return quota ? "换个号，或者等额度恢复" : "换一张重新做"
        }
    }

    private var isFailed: Bool { if case .failed = stage { return true }; return false }

    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tw.gray50)
            // ★ 2026-11-09：框内的动态背景（做好 / 失败就停）
            FlowBg(on: !isFailed && stage != .done)
            VStack(spacing: 6) {
                Text(insideMain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isFailed ? Tw.red600 : Tw.gray900)
                    .multilineTextAlignment(.center)
                if !insideSub.isEmpty {
                    Text(insideSub)
                        .font(.system(size: 12))
                        .foregroundStyle(Tw.gray500)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var titleText: String {
        switch stage {
        case .done: return "做好了"
        case .failed: return "生成失败"
        default: return "制作中"
        }
    }

    private var subText: String {
        switch stage {
        case .done: return "点下一步进动作库，接着做剩下的"
        case .failed: return ""
        default: return "这一条：" + actLabel
        }
    }

    /// 只有「做好了」才给「确认下一步」；失败不论什么原因，一颗「确认」；其余不给按钮。
    /// ★ 2026-11-10（他定的）：以前按「是不是额度」换成「换个号 / 换一张图」，
    ///   两颗其实走同一条路，还让他以为点不同的键会有不同结果。现在统一叫「确认」，
    ///   点下去照安卓那样真回到参考图页，换图换号都在那一页做。
    private var keyText: String? {
        switch stage {
        case .done: return "确认下一步"
        case .failed: return "确认"
        default: return nil
        }
    }

    private func tapKey() {
        switch stage {
        case .done: onNext()
        default: onBackToRef()
        }
    }

    // MARK: - 轮询（先问 wan，它说"没做"再问 act/state）

    private func watch() async {
        lastOrder = UserDefaults.standard.string(forKey: "still.lastorder." + char.id) ?? ""
        while alive {
            if let w = await ActLab.wanState(charId: char.id, act: act),
               let ws = w.状态, !ws.isEmpty, ws != "没做" {
                let why = w.人话 ?? ""
                switch ws {
                case "好了":
                    await 装进手机()
                case "失败":
                    stage = .failed(why.isEmpty ? "没做成" : why, why.contains("额度"))
                case "生成中":
                    stage = .generating
                default:
                    stage = .queue
                }
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                continue
            }

            if let st = await ActLab.state(charId: char.id),
               let a = st.acts.first(where: { $0.act == act }) {
                let s = a.状态
                let why = a.人话 ?? ""
                switch s {
                case "好了":
                    await 装进手机()
                case "失败", "没做成", "被打断":
                    let quota = why.contains("额度") || why.contains("付费")
                    // ★★ 2026-11-09（对齐安卓 SitingActivity:237-238）：没原因就只写
                    //   「没做成」，一个字都不编 —— 删掉按「额度」字样推断的那句。
                    stage = .failed(why.isEmpty ? "没做成" : why, quota)
                case "排队", "排队中", "准备中":
                    stage = .queue
                case "生成中":
                    stage = .generating
                case "等抠图", "抠像中", "正在送到手机":
                    // ★ 2026-11-09：这三段全归「抠图中」，不再各自成段
                    stage = .matting(parsePct(why))
                    if s == "正在送到手机" { await 装进手机() }
                case "没做":
                    // 台子上还没有这一条：刚下完单的几秒是正常的。
                    // ★ 2026-11-09：保持排队，不判失败、不编「机器在重启」、
                    //   不诱导重新点「开始生成」。失败只认台子状态字面。
                    stage = .queue
                default:
                    stage = .queue
                }
            }
            // ★ 2026-11-09：状态暂时拿不到（网络失败 / 解析失败）＝「不知道」，
            //   保持当前阶段继续等，绝不判失败、绝不踢回去重新下单。
            try? await Task.sleep(nanoseconds: 2_200_000_000)
        }
    }

    // MARK: - 装进手机（★ 他定的：装好才算完成，才给「确认下一步」）

    /// ★ 2026-11-09：**带台子 stamp 比对的强制安装**。
    ///   `CatPackStore.install(force: false)` 只要本地有 pack.zip 就返回旧包、不比版本，
    ///   台子新抠的那一版永远进不了手机。这里照 `PackEvents.deliver` 的口径：
    ///   本地 stamp 落后 / 本地没这一条 ⇒ `force: true` 强制重下，装好才置 .done。
    ///   装好回报一次 /api/act/installed，台子才会把「正在送到手机」改成「好了」。
    ///   失败把原因摆出来，不再吞掉停在「抠图中」不吭声。
    private func 装进手机() async {
        if 本机有 {
            stage = .done
            return
        }
        if 装包中 { stage = .packing; return }
        // 装不上时别每 2 秒重下一遍几十兆，等一会儿再来
        if Date().timeIntervalSince(上次装包失败) < 25 {
            stage = .packing
            return
        }
        装包中 = true
        defer { 装包中 = false }
        stage = .packing
        装包原因 = ""
        do {
            let m = try await ActLab.manifest(charId: char.id)
            guard m.stamp > 0 else {
                // 台子还没给版本号：下一轮再来。★ 必须上冷却，
                //   否则 watch 每 2.2 秒就打一次清单，能把台子敲死。
                上次装包失败 = Date()
                装包原因 = "还没拿到这一版的号，过一会儿再试"
                return
            }
            let key = "still.packstamp." + char.id
            let local = Int64(UserDefaults.standard.integer(forKey: key))
            let p: CatPack
            if local >= m.stamp,
               let old = CatPackStore.shared.installed(char.id), 有这一条(old) {
                // 本机这一版就是台子最新那版，直接用，不重复下几十兆
                p = old
            } else {
                // ★ 版本落后 / 本机没有这一条：强制重下，不认旧包
                p = try await CatPackStore.shared.install(charId: char.id, force: true)
            }
            guard 有这一条(p) else {
                上次装包失败 = Date()
                装包原因 = "下下来的包里没有这一条"
                return
            }
            if CatPackStore.shared.isCurrent(char.id) { CatPackStore.shared.use(p) }
            // ★★★ 先回报、回报成了才把本地版本号记成最新。
            //   反过来（先记后报）时，万一这一句没送到，本机以为已经装好最新版，
            //   下轮比对版本就直接跳过，台子永远收不到 installed ⇒
            //   状态会永久卡在「正在送到手机」。这正是老猫被踢回参考图页的源头。
            if await 回报装好(stamp: m.stamp) {
                UserDefaults.standard.set(m.stamp, forKey: key)
                本机有 = true
                stage = .done
            } else {
                上次装包失败 = Date()
                装包原因 = "还没跟台子对上，过一会儿会自动再试"
                stage = .packing
            }
        } catch {
            // ★ 装包失败：把原因摆出来（不再吞掉、停在「抠图中」不吭声）
            上次装包失败 = Date()
            装包原因 = error.localizedDescription
            stage = .packing
        }
    }

    /// 手机说：这版整包我已经装进本地了（body 同 PackEvents.ack：char + stamp）。
    private func 回报装好(stamp: Int64) async -> Bool {
        do {
            let d = try await ActLab.rawPost("/api/act/installed",
                                             body: ["char": char.id, "stamp": stamp])
            let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            return (o?["ok"] as? Bool) ?? true
        } catch {
            return false
        }
    }

    private func 有这一条(_ p: CatPack) -> Bool {
        p.acts.contains { $0.name == act && $0.frames > 0 }
    }

    private func parsePct(_ why: String) -> Int {
        guard let i = why.firstIndex(of: "%"), i != why.startIndex else { return 0 }
        let num = why[why.startIndex..<i].filter { $0.isNumber }
        return Int(num) ?? 0
    }
}

// MARK: - 框内动态背景

/// 两个很淡的柔光在框里缓慢游走 + 呼吸。
/// 全是动画、不带任何数字，所以不违反「界面上的数字必须是机器上真有的」。
private struct FlowBg: View {
    var on: Bool
    @State private var t: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let m = min(g.size.width, g.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 0.90, green: 0.90, blue: 0.88).opacity(0.60), .clear],
                        center: .center, startRadius: 0, endRadius: m * 0.62))
                    .frame(width: m * 1.28, height: m * 1.28)
                    .offset(x: -g.size.width * 0.16 + t * g.size.width * 0.10,
                            y: -g.size.height * 0.12 + t * g.size.height * 0.09)
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 0.87, green: 0.87, blue: 0.85).opacity(0.45), .clear],
                        center: .center, startRadius: 0, endRadius: m * 0.55))
                    .frame(width: m * 1.12, height: m * 1.12)
                    .offset(x: g.size.width * 0.18 - t * g.size.width * 0.08,
                            y: g.size.height * 0.14 - t * g.size.height * 0.10)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .clipped()
        .allowsHitTesting(false)
        .opacity(on ? 1 : 0)
        .animation(.easeInOut(duration: 0.5), value: on)
        .onAppear {
            withAnimation(.easeInOut(duration: 6.8).repeatForever(autoreverses: true)) { t = 1 }
        }
    }
}
