import SwiftUI

// MARK: - ② 制作中（只看「坐立」这一条）
//
// ★ 2026-11-01（他定的流程）：
//   · 只有一个大框（屏宽-32 的正方形），**不写动作名**，只有「制作中」
//   · 进度条跟其他动作**同一条**（排队中/生成中/等抠图/抠像中 47%…）
//   · 这页退出再进来还是这页，直到坐立真做好
//   · 做好后：大框里直接播坐立动图，底部才出现「确认下一步」
//   · 没做成：侵权 →「请换一张图」；额度不够 →「额度不够」；都退回①参考图页

struct SitingView: View {

    let char: ActLab.Char
    /// 退回参考图页（失败时走这条）
    var onBackToRef: () -> Void
    /// 点「确认下一步」→ 进动作库
    var onNext: () -> Void

    @State private var stage = ""
    @State private var pct = 0
    @State private var note = ""
    @State private var done = false
    @State private var alive = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onBackToRef() } label: {
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

            Spacer(minLength: 10)

            // 大框：做好了就播坐立动图
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Tw.gray100)
                if done {
                    GifView(url: GifView.makeURL(char.id, "sit", width: 720))
                        .padding(10)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(stageWord.isEmpty ? "制作中" : stageWord)
                            .font(.system(size: 13))
                            .foregroundStyle(Tw.gray500)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 16)

            Spacer(minLength: 14)

            Text(done ? "做好了" : "制作中")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tw.gray900)

            // 进度条：跟其他动作同一条
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tw.gray200)
                    Capsule().fill(Tw.gray900)
                        .frame(width: g.size.width * CGFloat(progress))
                }
            }
            .frame(height: 5)
            .padding(.horizontal, 40)
            .padding(.top, 14)

            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Tw.red600)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 10)
            }

            Spacer(minLength: 16)

            if done {
                Button { onNext() } label: {
                    Text("确认下一步")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Tw.gray900))
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .padding(.horizontal, 24)
            } else if !note.isEmpty {
                Button { onBackToRef() } label: {
                    Text("请换一张图")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tw.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Tw.gray900))
                }
                .buttonStyle(PressStyle(scale: 0.97))
                .padding(.horizontal, 24)
            }

            Spacer(minLength: 24)
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { await watch() }
        .onDisappear { alive = false }
    }

    /// 0~1：只有"抠像"那一段有真百分比，其余按阶段给一个粗略位置
    private var progress: Double {
        switch stage {
        case "排队中": return 0.08
        case "准备中": return 0.16
        case "生成中": return 0.35
        case "等抠图": return 0.62
        case "抠像中": return 0.62 + 0.30 * (Double(pct) / 100.0)
        default: return done ? 1.0 : 0.04
        }
    }

    private var stageWord: String {
        if stage == "抠像中" && pct > 0 { return "抠像中 \(pct)%" }
        return stage
    }

    private func watch() async {
        while alive {
            if let st = await ActLab.state(charId: char.id) {
                if let a = st.acts.first(where: { $0.act == "sit" }) {
                    stage = a.状态
                    note = a.人话
                    pct = 0
                    if a.状态 == "好了" { done = true; stage = "好了" }
                    if a.状态 == "失败" || a.状态 == "没做成" {
                        // 侵权 → 请换一张图；额度不够 → 额度不够
                        let why = a.人话
                        note = why.contains("额度") || why.contains("付费") ? "额度不够" : "请换一张图"
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
        }
    }
}
