import SwiftUI

// MARK: - 它给你带的礼物 + 「让它自己买」的开关（方案 D：算力回收）
//
// ★★ 关键：**没翻开之前，一个字都不许透露它买了什么** —— 这是惊喜。
//    只写「它给你带了东西 / 点开看看是什么」。
//
// ★ 取不到就不画 —— 界面上不许出现没数的东西。
//   没授权、账上没算力、它还没买 ⇒ 这里只留那个开关（关着的状态也要让他看得见、
//   知道有这回事），不会凭空冒出一张空卡片吓人。

struct GiftCardsView: View {
    @State private var info: CreditInfo?
    @State private var opening: CreditGift?
    @State private var askQuota = false
    @State private var quotaText = ""

    var body: some View {
        Group {
            if let i = info {
                ForEach(i.unopened) { g in
                    surpriseRow(g)
                }
                switchRow(i)
            }
        }
        .task { info = await Credit.load() }
        // 揭晓：点开才知道是什么
        .alert(opening?.name ?? "它给你带了东西",
               isPresented: Binding(get: { opening != nil },
                                    set: { if !$0 { opening = nil } })) {
            Button("收下了") {
                if let g = opening {
                    Task {
                        await Credit.opened(g.id)
                        info = await Credit.load()
                    }
                }
                opening = nil
            }
        } message: {
            Text(detail(of: opening))
        }
        // 事前授权一次：填一个每月额度
        .alert("让它自己给我买礼物", isPresented: $askQuota) {
            TextField("每月最多多少算力", text: $quotaText)
                .keyboardType(.numberPad)
            Button("算了", role: .cancel) { }
            Button("存下") {
                let q = Int(quotaText.trimmingCharacters(in: .whitespaces)) ?? 0
                Task {
                    await Credit.authorize(on: q > 0, quota: q)
                    info = await Credit.load()
                }
            }
        } message: {
            Text("给它一个每月上限，它就在这个数里自己挑、自己买 —— 买什么不提前告诉你，这是惊喜。\n"
                 + "额度用完就停。你留着的算力里有三成它永远碰不到，不会出现没法跟它说话。\n"
                 + "填 0 = 关掉。")
        }
    }

    // MARK: - 那张「它给你带了东西」

    private func surpriseRow(_ g: CreditGift) -> some View {
        Button { opening = g } label: {
            HStack(spacing: 9) {
                Text("🎁")
                    .font(.system(size: 17))
                VStack(alignment: .leading, spacing: 1) {
                    Text("它给你带了东西")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Tw.gray900)
                    Text("点开看看是什么")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tw.gray500)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tw.red50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Tw.red200, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .padding(.bottom, 10)
    }

    // MARK: - 「让它自己买」的开关

    private func switchRow(_ i: CreditInfo) -> some View {
        Button { quotaText = String(i.auth?.quota ?? 0); askQuota = true } label: {
            HStack(spacing: 9) {
                Text("✦")
                    .font(.system(size: 17))
                    .foregroundStyle((i.auth?.on ?? false) ? Tw.red600 : Tw.gray400)
                VStack(alignment: .leading, spacing: 1) {
                    Text("让它自己给我买礼物")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(Tw.gray900)
                    Text(sub(of: i))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Tw.gray500)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tw.gray100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Tw.gray200, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .padding(.bottom, 10)
    }

    private func sub(of i: CreditInfo) -> String {
        if let a = i.auth, a.on {
            return "每月最多 \(a.quota) 算力 · 这个月它花了 \(i.monthSpent) · 它自己决定买什么，不提前告诉你"
        }
        return "关着 · 它不会自己买，只会陪你说话"
    }

    private func detail(of g: CreditGift?) -> String {
        guard let g else { return "" }
        var s = g.desc.isEmpty ? g.name : g.desc
        if !g.note.isEmpty { s += "\n\n「\(g.note)」" }
        s += "\n\n它花了 \(g.cost) 算力"
        switch g.status {
        case "已发货": s += " · 已经在路上了"
        case "已收到": s += " · 你已经收到了"
        default:       s += " · 已经下单了"
        }
        return s
    }
}
