import SwiftUI

// MARK: - ② 制作中（只看「坐立」这一条）—— 2026-11-02 定稿八屏
//
// 规矩（全部来自他）：
//  · 框＝动作库那一格放大（屏宽-40、比例 1.32），不是铺满整页的长方形
//  · 只有进行中的阶段有进度条：排队中/准备中/正在生成/生成完毕/抠像中
//  · 做好了：进度条消失、框里播坐立、底部「确认下一步」
//  · 生成失败：原因写在框里、进度条消失；侵权→「换一张图」，额度→「换个号」
//  · 这一页**不下单**（下单在参考图页那颗「开始生成」上）

struct SitingView: View {

    let char: ActLab.Char
    /// ★ 2026-11-03：这一页现在能给**任意动作**用（以前写死 sit）
    var act: String = "sit"
    var actLabel: String = "坐着张望"
    var onBackToRef: () -> Void
    var onNext: () -> Void

    private enum Phase {
        case queue, prepare, generating, matted, matting(Int), done, failed(String)
    }

    @State private var phase: Phase = .prepare
    /// ★ wan 那条通道的人话（"已经等了 N 秒"）
    @State private var wanHint: String = ""
    @State private var alive = true

    private var cellW: CGFloat { UIScreen.main.bounds.width - 40 }
    private var cellH: CGFloat { cellW / 1.32 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onBackToRef() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Tw.gray100))
                }
                .buttonStyle(PressStyle(scale: 0.9))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Tw.gray100)
                content
            }
            .frame(width: cellW, height: cellH)
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
                if case .generating = phase {
                    // ★ 2026-11-03：生成阶段没有真百分比 → 光带（不确定态）
                    LightBandView()
                        .padding(.top, 8)
                } else if let p = progress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tw.gray200)
                            Capsule().fill(Tw.gray900).frame(width: max(4, g.size.width * p))
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 20)

            Spacer(minLength: 12)

            if let key = bottomKey {
                Button { key.1() } label: {
                    Text(key.0)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Tw.gray900))
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            } else {
                Color.clear.frame(height: 24)
            }
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { await watch() }
        .onDisappear { alive = false }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .done:
            GifView(url: GifView.makeURL(char.id, "sit", width: 720)).padding(10)
        case .failed(let why):
            VStack(spacing: 6) {
                Text(why).font(.system(size: 16, weight: .semibold)).foregroundStyle(Tw.red600)
                Text(why.contains("额度") ? "换个号，或者等额度恢复" : "换一张重新做")
                    .font(.system(size: 12)).foregroundStyle(Tw.gray400)
            }
        case .matting(let pct):
            VStack(spacing: 8) {
                Text("\(pct)%").font(.system(size: 16, weight: .semibold)).foregroundStyle(Tw.gray900)
                Text("正在抠背景").font(.system(size: 12)).foregroundStyle(Tw.gray400)
            }
        case .generating:
            VStack(spacing: 6) {
                ProgressView()
                Text("正在生成").font(.system(size: 15, weight: .semibold))
                Text("3–5 分钟").font(.system(size: 12)).foregroundStyle(Tw.gray400)
            }
        default:
            VStack(spacing: 6) {
                Text(mainText).font(.system(size: 15, weight: .semibold)).foregroundStyle(Tw.gray700)
                if !subText.isEmpty {
                    Text(subText).font(.system(size: 12)).foregroundStyle(Tw.gray400)
                }
            }
        }
    }

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    private var mainText: String {
        switch phase {
        case .queue: return "排队中"
        case .prepare: return "准备中"
        case .matted: return "生成完毕"
        default: return ""
        }
    }

    private var titleText: String {
        switch phase {
        case .queue, .prepare, .generating, .matted, .matting: return "制作中"
        case .done: return "做好了"
        case .failed: return "生成失败"
        }
    }

    private var subText: String {
        switch phase {
        case .queue: return "前面还有活在做，轮到它就开始"
        case .prepare: return "已经交出去了，马上开始"
        case .generating: return wanHint.isEmpty ? ("这一条：" + actLabel) : wanHint
        case .matted: return "片子拿到了，下一步去背景"
        case .matting: return "只有这一步有真百分比"
        case .done: return "点下一步进动作库，接着做剩下的"
        case .failed: return ""
        }
    }

    private var progress: CGFloat? {
        switch phase {
        case .queue: return 0.08
        case .prepare: return 0.12
        case .generating: return 0.40
        case .matted: return 0.62
        case .matting(let p): return 0.62 + 0.30 * CGFloat(p) / 100
        case .done, .failed: return nil
        }
    }

    private var bottomKey: (String, () -> Void)? {
        switch phase {
        case .done: return ("确认下一步", { markSeen(); onNext() })
        case .failed(let why):
            return why.contains("额度") ? ("换个号", onBackToRef) : ("换一张图", onBackToRef)
        default: return nil
        }
    }

    /// ★ 2026-11-03：点「确认下一步」→ 记住他看过这一屏，以后不再拦。
    private func markSeen() {
        UserDefaults.standard.set(true, forKey: "still.seensit." + char.id)
    }

    private func watch() async {
        lastOrder = UserDefaults.standard.string(forKey: "still.lastorder." + char.id) ?? ""
        var pollCount = 0
        while alive {
            // ★ 2026-11-02：wan3.0 是**用户在下拉条里选的另一条通道**，
            //   它有自己的状态口径（排队中/生成中 + 已等 N 秒）。先问它；
            //   它说"没做"才回去问原来那套。
            pollCount += 1
            if pollCount % 30 == 0 {
                // ★ 2026-11-03：把轮询看到的原始状态报上去，
                //   否则"一直准备中"我这边只能猜。
                if let d = await ActLab.wanState(charId: char.id, act: act) {
                    let ws = d.状态 ?? "?"
                    let ss: String
                    if let st = await ActLab.state(charId: char.id),
                       let a = st.acts.first(where: { $0.act == act }) {
                        ss = a.状态
                    } else { ss = "读不到" }
                    await ActLab.diagSay("制作中轮询 char=\(char.id) act=\(act) wan=\(ws) act状态=\(ss)")
                }
            }
            if let w = await ActLab.wanState(charId: char.id, act: act),
               let ws = w.状态, !ws.isEmpty, ws != "没做" {
                if ws == "好了" {
                    phase = .done
                } else if ws == "失败" {
                    let why = w.人话 ?? ""
                    phase = .failed(why.isEmpty ? "再试一次，或者换一张图" : why)
                } else if ws == "排队中" {
                    phase = .queue
                } else if ws == "生成中" {
                    // 不编百分比：只把"已等多久"写进人话
                    let waited = w.已等 ?? 0
                    phase = .generating
                    wanHint = "已经等了 \(waited) 秒（通常 2–4 分钟）"
                } else {
                    phase = .prepare
                }
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                continue
            }
            if let st = await ActLab.state(charId: char.id),
               let a = st.acts.first(where: { $0.act == act }) {
                let s = a.状态
                if s == "没做" { missingPolls += 1 } else { missingPolls = 0 }
                let why = a.人话 ?? ""
                switch s {
                case "没做":
                    // ★ 2026-11-03：台子上根本没有这一条 —— 要么还没落到盘上（刚下单几秒），
                    //   要么这一单在机器重启时丢了。等 45 秒还查不到就明说，别让人干等。
                    if missingPolls >= 20 {
                        phase = .failed("台子上查不到这一单（可能下单时机器在重启）—— 点下面这颗退回去，重新点一次「开始生成」")
                    } else {
                        phase = .prepare
                    }
                case "好了": phase = .done
                case "排队", "排队中": phase = .queue
                case "生成中": phase = .generating
                case "等抠图": phase = .matted
                case "抠像中": phase = .matting(parsePct(why))
                case "失败", "没做成":
                    phase = .failed(why.contains("额度") ? "豆包额度不够" : "这张图涉及侵权")
                default: phase = .prepare
                }
            }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
        }
    }

    private func parsePct(_ why: String) -> Int {
        guard let i = why.firstIndex(of: "%") else { return 0 }
        let num = why[why.startIndex..<i].filter { $0.isNumber }
        return Int(num) ?? 0
    }
}
