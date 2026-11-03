import SwiftUI
import UIKit

// ★ 2026-11-03（他报的"iOS 动作点生成没反应"）：
//   这一页就是 iOS 缺的那张「生成这一条」——跟安卓 GenSetupActivity 对齐：
//     · 显示要生成哪一个动作
//     · 「用哪个做」：wan3.0 / 豆包号（两条线都能走）
//     · 开始生成（点两下确认，跟参考图页同一个规矩）
//     · 失败必须说出来（余额不足 / 台子报错），不能静默跳走

struct GenOneSheet: View {

    let char: ActLab.Char
    let act: String
    let label: String
    var onDone: (Bool) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var channel = "wan"
    @State private var accounts: [BaoAcc] = []
    @State private var awaitConfirm = false
    @State private var busy = false
    @State private var err: String?
    private var canStart: Bool {
        if channel == "wan" { return true }
        let slot = String(channel.dropFirst("doubao:".count))
        return accounts.first(where: { $0.id == slot })?.ok == true
    }

    struct BaoAcc: Identifiable { let id: String; let name: String; let ok: Bool }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 4) {
                    Text("要做哪一条").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                    Text(label).font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Tw.gray900)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("用哪个做").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tw.gray500)
                    Menu {
                        Button("wan3.0 · 阿里云") { channel = "wan" }
                        ForEach(accounts) { a in
                            Button("\(a.name) · \(a.ok ? "已登录" : "没登录")") { channel = "doubao:" + a.id }
                        }
                    } label: {
                        HStack {
                            Text(channelLabel).font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 11))
                                .foregroundStyle(Tw.gray400)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tw.gray50))
                    }
                }

                if channel.hasPrefix("doubao:") && !canStart {
                    Text("这个豆包号没登录 —— 先回登记页把它登上")
                        .font(.system(size: 12)).foregroundStyle(Tw.red600)
                }
                if let e = err {
                    Text(e).font(.system(size: 12)).foregroundStyle(Tw.red600)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if !awaitConfirm {
                        awaitConfirm = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if awaitConfirm { awaitConfirm = false }
                        }
                        return
                    }
                    awaitConfirm = false
                    Task { await start() }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(.white) }
                        Text(awaitConfirm ? "再点一次就开始" : "开始生成")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Tw.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(canStart ? Tw.gray900 : Tw.gray300))
                }
                .disabled(busy || !canStart)
                .buttonStyle(PressStyle(scale: 0.97))

                Spacer()
            }
            .padding(20)
            .navigationTitle("生成这一条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } } }
            .task { await loadAccounts() }
        }
    }

    private var channelLabel: String {
        if channel == "wan" { return "wan3.0 · 阿里云" }
        let slot = String(channel.dropFirst("doubao:".count))
        if let a = accounts.first(where: { $0.id == slot }) {
            return a.name + (a.ok ? " · 已登录" : " · 没登录")
        }
        return "豆包" + slot
    }

    private func loadAccounts() async {
        guard let d = try? await ActLab.rawGet("/api/login/accounts", timeout: 15),
              let obj = try? JSONSerialization.jsonObject(with: d),
              let o = obj as? [String: Any],
              let arr = o["账号"] as? [[String: Any]] else { return }
        var out: [BaoAcc] = []
        for x in arr {
            let s = (x["slot"] as? String) ?? "1"
            let n = (x["名字"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ("豆包" + s)
            out.append(BaoAcc(id: s, name: n, ok: (x["登着没"] as? Bool) ?? false))
        }
        accounts = out
    }

    private func start() async {
        busy = true
        err = nil
        defer { busy = false }
        do {
            if channel.hasPrefix("doubao:") {
                let slot = String(channel.dropFirst("doubao:".count))
                try await ActLab.genOrder(charId: char.id, act: act, slot: slot)
            } else {
                _ = try await ActLab.wanStart(charId: char.id, act: act)
            }
            await ActLab.diagSay("生成这一条下单成功 char=\(char.id) act=\(act) channel=\(channel)")
            let landed2 = await ActLab.verifyOrder(charId: char.id, act: act)
            if !landed2 {
                await ActLab.diagSay("生成这一条下单后查不到 char=\(char.id) act=\(act)")
                err = "这一单没落到台子上（机器刚被重启），再点一次就好"
                return
            }
            onDone(true)
            dismiss()
        } catch {
            let msg = (error as NSError).localizedDescription
            err = msg.isEmpty ? "下单没成功，再试一次" : msg
            await ActLab.diagSay("生成这一条下单失败 char=\(char.id) act=\(act) 原因=\(err ?? "")")
        }
    }
}
