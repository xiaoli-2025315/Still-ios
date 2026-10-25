import SwiftUI

// ══════════════════════════════════════════════════════════════════════
// ★★★ v94（他的原话）：
//   「每一批做完了之后跳出一个弹窗汇报：这次生成了几条、没生成出来的是哪几条、原因写上，
//     然后两个选项：把没生成成功的再生成一遍 / 先不生成了」
//   「只要这批任务一做完……**不管我当前在这个APP的任意界面，都弹出来**」
//
// 所以弹窗挂在**整个 App 的最外层**（ContentView 上盖一层），不是挂在某一个页面里 ——
// 那样他一离开那一页就再也收不到汇报了。
//
// ★ 它只做"汇报 + 让他选"，机器绝不自己替他开工。
// ══════════════════════════════════════════════════════════════════════

/// 没做成的那一条：名字 + 机器给的原因。
struct SettleMiss {
    let act: String
    let why: String
}

/// 一张结算单：这批做完了，成了哪些、没成哪些。
struct SettleNote: Identifiable {
    let char: String
    let name: String
    let ok: [String]
    let miss: [SettleMiss]
    let at: Double

    var id: String { char + "_" + String(Int(at)) }

    static func from(_ o: [String: Any]) -> SettleNote? {
        guard let c = o["char"] as? String, !c.isEmpty else { return nil }
        let miss = ((o["没成"] as? [[String: Any]]) ?? []).compactMap { d -> SettleMiss? in
            guard let a = d["act"] as? String else { return nil }
            return SettleMiss(act: a, why: (d["为什么"] as? String) ?? "")
        }
        return SettleNote(
            char: c,
            name: (o["名"] as? String) ?? "",
            ok: (o["成了"] as? [String]) ?? [],
            miss: miss,
            at: (o["于"] as? Double) ?? 0
        )
    }

    /// 动作英文翻成他说得懂的中文
    static func 中文(_ key: String) -> String {
        ActLab.official.first(where: { $0.key == key })?.label ?? key
    }
}

extension Notification.Name {
    /// 结算弹窗里他做了选择（object = 那只猫的 id）⇒ 制作页要立刻跟着刷新
    static let stillSettleDone = Notification.Name("still.settle.done")
}

final class SettleBell: ObservableObject {
    static let shared = SettleBell()

    @Published var 当前: SettleNote? = nil
    @Published var 忙 = false

    private var 弹过 = Set<String>()
    private var 起了 = false

    init() { }

    func 起() {
        let go: Bool = 起了 ? false : true
        guard go else { return }
        起了 = true
        // ★ 轮询放在后台跑；凡是要动界面上的东西（当前/弹过）一律回到主线程再改。
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self else { return }
                await self.查()
            }
        }
    }

    private func 查() async {
        let 手上有: SettleNote? = await MainActor.run { 当前 }
        let 忙着: Bool = await MainActor.run { 忙 }
        if 手上有 != nil || 忙着 { return }              // 手上还弹着就别抢

        guard let list = try? await ActLab.genSettle() else { return }
        for s in list {
            let 弹过没有: Bool = await MainActor.run { 弹过.contains(s.id) }
            if 弹过没有 { continue }
            await MainActor.run {
                弹过.insert(s.id)
                当前 = s
            }
            return
        }
    }

    /// 他选好了。再来=true ⇒ 把没做成的那几条重新安排上（机器只做缺的，不会重画做好的）。
    func 办(_ s: SettleNote, 再来: Bool) async {
        await MainActor.run { 当前 = nil }
        try? await ActLab.genSettleAck(char: s.char, 再来: 再来)
        if 再来 {
            _ = try? await ActLab.genStart(charId: s.char)      // 空 action = 只做还缺的
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .stillSettleDone, object: s.char)
        }
    }
}

// MARK: - 弹窗（盖在整个 App 上面）

struct SettleBellView: View {
    @StateObject private var bell = SettleBell.shared

    var body: some View {
        ZStack {
            if let s = bell.当前 {
                Color.black.opacity(0.34).ignoresSafeArea()
                    .onTapGesture { }                    // 点背景不关 —— 必须让他选一个
                卡片(s)
                    .padding(.horizontal, 26)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: bell.当前?.id)
        .onAppear { bell.起() }
    }

    private func 卡片(_ s: SettleNote) -> some View {
        let nBad = s.miss.count
        return VStack(alignment: .leading, spacing: 12) {
            Text(nBad > 0 ? "这一批做完了" : "这一批全做好了")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.12))

            VStack(alignment: .leading, spacing: 6) {
                if !s.ok.isEmpty {
                    Text("这次做好了 \(s.ok.count) 个：" + s.ok.map { SettleNote.中文($0) }.joined(separator: "、"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.45))
                } else {
                    Text("这次一个都没做成。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.45))
                }
                if nBad > 0 {
                    Text("这 \(nBad) 个没做出来：")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color(red: 0.70, green: 0.15, blue: 0.15))
                    ForEach(s.miss, id: \.act) { m in
                        Text("· " + SettleNote.中文(m.act) + (m.why.isEmpty ? "" : " —— " + m.why))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.45))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    bell.忙 = true
                    Task { await bell.办(s, 再来: nBad > 0); bell.忙 = false }
                } label: {
                    键(nBad > 0 ? "把没做成的再来一遍" : "知道了", filled: true)
                }
                .buttonStyle(.plain)
                .disabled(bell.忙)

                if nBad > 0 {
                    Button {
                        bell.忙 = true
                        Task { await bell.办(s, 再来: false); bell.忙 = false }
                    } label: {
                        键("先不做了", filled: false)
                    }
                    .buttonStyle(.plain)
                    .disabled(bell.忙)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
        )
    }

    private func 键(_ t: String, filled: Bool) -> some View {
        Text(t)
            .font(.system(size: 13, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(filled ? Color.white : Color(red: 0.25, green: 0.25, blue: 0.27))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(filled ? Color(red: 0.86, green: 0.15, blue: 0.15)
                                 : Color(red: 0.96, green: 0.96, blue: 0.97))
            )
    }
}
