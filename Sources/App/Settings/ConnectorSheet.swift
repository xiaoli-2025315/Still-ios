// 连接器浮窗（2026-11-24）：设置页「连接器」那行点进来。
// 数据来自台子 /api/connector/list（rawGet/rawPost 自动贴票、带分享码）。
// ★ 需要企业后台的那批（ready=false）只列位、点了提示先不接，不存钥匙。
// ★ Key 只往服务器发一次，界面和日志都不留。

import SwiftUI

struct ConnectorPayload: Decodable {
    let ok: Bool?
    let groups: [ConnectorGroup]
}
struct ConnectorGroup: Decodable {
    let group: String
    let items: [ConnectorItem]
}
struct ConnectorItem: Decodable {
    let id: String
    let name: String
    let logo: String
    let intro: String
    let auth: String
    let ready: Bool
    let tag: String?
    let on: Bool
    let name2: String?
}
struct ConnectorMsg: Decodable {
    let ok: Bool?
    let shuo: String?
    let cuowu: String?
    enum CodingKeys: String, CodingKey {
        case ok
        case shuo = "说"
        case cuowu = "错误"
    }
    var isOK: Bool { ok != false }
}

struct ConnectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ConnectorGroup] = []
    @State private var loaded = false
    @State private var note = ""
    @State private var showDoubao = false

    // 填 Key
    @State private var keyTarget: ConnectorItem? = nil
    @State private var keyText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Cfg.Palette.bg.ignoresSafeArea()
                if !loaded {
                    ProgressView().tint(Cfg.Palette.faint)
                } else if groups.isEmpty {
                    VStack(spacing: 10) {
                        Text("没读到连接器")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                        if !note.isEmpty {
                            Text(note).font(.system(size: 12)).foregroundStyle(Cfg.Palette.faint)
                                .multilineTextAlignment(.center)
                        }
                        if note.contains("登录") {
                            Text("回 App 重新登录一下，再进这里")
                                .font(.system(size: 11)).foregroundStyle(Tw.red600)
                        }
                        Button("再试一次") { Task { await 载入() } }
                            .buttonStyle(.borderedProminent).tint(Tw.red600)
                    }
                    .padding(.horizontal, 24)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("接在服务器上，手机不用装东西。连上后它就能替你查、替你办。")
                                .font(.system(size: 12)).foregroundStyle(Cfg.Palette.faint)
                                .padding(.bottom, 12)
                            ForEach(groups, id: \.group) { g in
                                Text(g.group)
                                    .font(.system(size: 11)).foregroundStyle(Cfg.Palette.faint)
                                    .padding(.top, 10).padding(.bottom, 6)
                                VStack(spacing: 0) {
                                    ForEach(g.items, id: \.id) { it in
                                        一行(it)
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Tw.white)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Tw.gray200, lineWidth: 1)
                                )
                            }
                            Text("点右边的 ＋ 连接 · 连上变 ✓ · 豆包登录过期会自己变回 ＋")
                                .font(.system(size: 11)).foregroundStyle(Cfg.Palette.faint)
                                .padding(.top, 14)
                            if !note.isEmpty {
                                Text(note).font(.system(size: 12)).foregroundStyle(Cfg.Palette.faint)
                                    .padding(.top, 6)
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                }
            }
            .navigationTitle("连接器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关上") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await 载入() }
        .sheet(isPresented: $showDoubao) {
            DoubaoLoginPage().presentationDetents([.large])
        }
        .alert("连接", isPresented: Binding(
            get: { keyTarget != nil },
            set: { if !$0 { keyTarget = nil } }
        )) {
            TextField("把申请到的 Key 贴这儿", text: $keyText)
            Button("取消", role: .cancel) { keyTarget = nil }
            Button("连接并测试") {
                if let t = keyTarget { Task { await 存(t, keyText) } }
            }
        } message: {
            Text("Key 只发给你的服务器保存，不会留在手机上。")
        }
    }

    private func 一行(_ it: ConnectorItem) -> some View {
        Button {
            点(it)
        } label: {
            HStack(spacing: 9) {
                Text(it.logo)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray900)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Tw.gray50))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tw.gray200, lineWidth: 1))
                Text("⛓").font(.system(size: 15)).foregroundStyle(Tw.red600)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(it.name).font(.system(size: 13)).foregroundStyle(Tw.gray900)
                        if let tag = it.tag, !tag.isEmpty {
                            Text(tag).font(.system(size: 9)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Tw.red600))
                        }
                    }
                    Text(it.intro).font(.system(size: 10)).foregroundStyle(Tw.gray500)
                }
                Spacer(minLength: 6)
                Text(it.on ? "✓" : "＋")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(it.on ? Tw.green500 : Tw.gray400)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func 载入() async {
        do {
            // ★ 2026-11-25：服务端这条只注册在 POST 区，之前 GET 打的是空路由
            let data = try await ActLab.rawPost("/api/connector/list", body: [String: Any]())
            let p = try JSONDecoder().decode(ConnectorPayload.self, from: data)
            if p.ok != false {
                groups = p.groups
                note = ""
            } else {
                groups = []
                note = "服务器没把连接器读出来"
            }
        } catch {
            groups = []
            note = "连不上服务器：\(error.localizedDescription)"
        }
        loaded = true
    }

    private func 点(_ it: ConnectorItem) {
        if !it.ready {
            note = "这个要企业后台人工授权，这一批先不接"
            return
        }
        if it.id == "doubao" {
            showDoubao = true
            return
        }
        if it.on {
            断(it)
            return
        }
        if it.auth == "key" {
            keyText = ""
            keyTarget = it
        } else {
            note = "这个连接器这一批还连不了"
        }
    }

    private func 存(_ it: ConnectorItem, _ key: String) async {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do {
            let d = try await ActLab.rawPost("/api/connector/auth",
                body: ["cid": it.id, "key": k, "name": it.name])
            guard (try? JSONDecoder().decode(ConnectorMsg.self, from: d))?.isOK == true else {
                note = "没连上，检查一下 Key 再试"; return
            }
            var say = "连上了"
            if let td = try? await ActLab.rawPost("/api/connector/test", body: ["cid": it.id]),
               let tm = try? JSONDecoder().decode(ConnectorMsg.self, from: td) {
                say = tm.shuo ?? say
            }
            note = say
            await 载入()
        } catch {
            note = "没连上，检查一下 Key 再试"
        }
        keyTarget = nil
    }

    private func 断(_ it: ConnectorItem) {
        Task {
            do {
                let d = try await ActLab.rawPost("/api/connector/revoke", body: ["cid": it.id])
                if (try? JSONDecoder().decode(ConnectorMsg.self, from: d))?.isOK == true {
                    note = "已断开"
                    await 载入()
                }
            } catch { note = "没断开，等下再试" }
        }
    }
}
