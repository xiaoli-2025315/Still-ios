import SwiftUI
import UIKit

// MARK: - ② 制作中（照安卓 SitingActivity 逐段搬，2026-11-03 重写）
//
// 规矩全部照安卓，一条不改：
//  · 框里显示"这一步在干什么"：准备中 / 排队中 / 正在生成 / 生成完毕 / 抠像中 / 失败原因 / 做好了
//  · 只有进行中的阶段有进度条：排队 0.08、准备 0.12、生成 0.40、等抠图 0.62、抠像 0.62+0.30×百分比
//  · 失败：**原因写在框里**（红字），标题「生成失败」，按钮「换个号」/「换一张图」
//  · 好了：标题「做好了」，按钮「确认下一步」
//  · 这一页不下单（下单在参考图页）

struct SitingView: View {

    let char: ActLab.Char
    var act: String = "sit"
    var actLabel: String = "坐着张望"
    var onBackToRef: () -> Void = {}
    var onNext: () -> Void = {}

    private enum Stage: Equatable {
        case prepare
        case queue
        case generating
        case matted
        case matting(Int)
        case done
        case failed(String, Bool)      // 原因, 是不是额度问题
    }

    @State private var stage: Stage = .prepare
    @State private var alive = true
    @State private var missingPolls = 0
    @State private var lastOrder = ""

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
                if case .generating = stage {
                    LightBandView().padding(.top, 8)
                } else if let p = barProgress {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tw.gray200)
                            Capsule().fill(Tw.gray900)
                                .frame(width: max(4, g.size.width * p))
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 8)
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

    // MARK: - 框里的字（= 安卓的 setInside）

    private var insideMain: String {
        switch stage {
        case .prepare: return "准备中"
        case .queue: return "排队中"
        case .generating: return "正在生成"
        case .matted: return "生成完毕"
        case .matting(let pct): return pct > 0 ? "\(pct)%" : "抠像中"
        case .done: return "做好了"
        case .failed(let why, _): return why
        }
    }

    private var insideSub: String {
        switch stage {
        case .prepare: return "已经交出去了，马上开始"
        case .queue: return "前面还有活在做，轮到它就开始"
        case .generating: return "3–5 分钟"
        case .matted: return "准备抠图"
        case .matting: return "正在抠背景"
        case .done: return ""
        case .failed(_, let quota): return quota ? "换个号，或者等额度恢复" : "换一张重新做"
        }
    }

    private var isFailed: Bool { if case .failed = stage { return true }; return false }

    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tw.gray50)
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
        case .matted: return "片子拿到了，下一步去背景"
        case .matting: return "只有这一步有真百分比"
        default: return "这一条：" + actLabel
        }
    }

    private var barProgress: Double? {
        switch stage {
        case .prepare: return 0.12
        case .queue: return 0.08
        case .generating: return 0.40
        case .matted: return 0.62
        case .matting(let pct): return 0.62 + 0.30 * (Double(pct) / 100.0)
        case .done, .failed: return nil
        }
    }

    private var keyText: String? {
        switch stage {
        case .done: return "确认下一步"
        case .failed(_, let quota): return quota ? "换个号" : "换一张图"
        default: return nil
        }
    }

    private func tapKey() {
        switch stage {
        case .done: onNext()
        default: onBackToRef()
        }
    }

    // MARK: - 轮询（照安卓：先问 wan，它说"没做"再问 act/state）

    private func watch() async {
        lastOrder = UserDefaults.standard.string(forKey: "still.lastorder." + char.id) ?? ""
        while alive {
            if let w = await ActLab.wanState(charId: char.id, act: act),
               let ws = w.状态, !ws.isEmpty, ws != "没做" {
                missingPolls = 0
                let why = w.人话 ?? ""
                switch ws {
                case "好了":
                    stage = .done
                case "失败":
                    stage = .failed(why.isEmpty ? "生成失败" : why, why.contains("额度"))
                case "排队中":
                    stage = .queue
                case "生成中":
                    stage = .generating
                default:
                    stage = .prepare
                }
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                continue
            }

            if let st = await ActLab.state(charId: char.id),
               let a = st.acts.first(where: { $0.act == act }) {
                let s = a.状态
                let why = a.人话 ?? ""
                if s == "没做" { missingPolls += 1 } else { missingPolls = 0 }
                switch s {
                case "好了":
                    stage = .done
                case "失败", "没做成":
                    let quota = why.contains("额度") || why.contains("付费")
                    stage = .failed(why.isEmpty ? (quota ? "豆包额度不够" : "这张图涉及侵权") : why, quota)
                case "排队", "排队中":
                    stage = .queue
                case "生成中":
                    stage = .generating
                case "等抠图":
                    stage = .matted
                case "抠像中":
                    stage = .matting(parsePct(why))
                case "没做":
                    // 台子上没有这一条：要么刚落盘（几秒），要么这单丢了
                    if missingPolls >= 20 {
                        stage = .failed("台子上查不到这一单（下单时机器可能在重启）—— 点下面退回，重新点一次「开始生成」", false)
                    } else {
                        stage = .prepare
                    }
                default:
                    stage = .prepare
                }
            } else {
                missingPolls += 1
                if missingPolls >= 20 && stage != .done {
                    stage = .failed("台子上查不到这一单（下单时机器可能在重启）—— 点下面退回，重新点一次「开始生成」", false)
                }
            }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
        }
    }

    private func parsePct(_ why: String) -> Int {
        guard let i = why.firstIndex(of: "%"), i != why.startIndex else { return 0 }
        let num = why[why.startIndex..<i].filter { $0.isNumber }
        return Int(num) ?? 0
    }
}
