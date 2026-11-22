import SwiftUI

// MARK: - 记忆页（2026-11-22）
//
// 看柜子里一份份文件：分类、搜索、点开看原件、能改、长按删、右上新建、撤销。
// ★ 先做能用的列表式，球的可视化后加 —— 先把柜子里的真东西摸到手。
// ★ 只显示台子真有的；断网 / 老台子没接口就是空页 + 一句人话，绝不编数据。

struct MemView: View {
    @State private var charId: String
    @Environment(\.dismiss) private var dismiss

    @State private var roles: [MemAPI.Role] = []
    @State private var cat = "它记住的"
    @State private var box: [String: [MemAPI.File]] = [:]
    @State private var q = ""
    @State private var loading = true
    @State private var openFile: MemAPI.File? = nil
    @State private var detail: MemAPI.Detail? = nil
    @State private var editText = ""
    @State private var newOpen = false
    @State private var newName = ""
    @State private var newText = ""
    @State private var note = ""
    @State private var ballMode = false   // ★ 六期：球/列表切换，默认列表（能用优先）

    init(charId: String) {
        _charId = State(initialValue: charId)
    }

    private var files: [MemAPI.File] {
        let arr = box[cat] ?? []
        let s = q.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? arr : arr.filter { $0.名.contains(s) || $0.摘要.contains(s) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在读它记得的事…").font(.system(size: 13)).foregroundStyle(Tw.gray400)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if files.isEmpty {
                    VStack(spacing: 8) {
                        Text("这里还没有什么").font(.system(size: 15, weight: .semibold))
                        Text("多跟它聊几句，或者用右上角＋塞一份进去。")
                            .font(.system(size: 13)).foregroundStyle(Tw.gray400)
                            .multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 32)
                } else if ballMode {
                    // ★ 六期：经纬网球，点 = 柜子真文件；点开看原件、长按删
                    MemBallView(files: files, hint: "",
                                onOpen: { f in Task { await 打开(f) } },
                                onLong: { f in Task { await 删(f) } })
                        .padding(.horizontal, 16)
                } else {
                    List {
                        ForEach(files) { f in
                            Button { Task { await 打开(f) } } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(f.名).font(.system(size: 15, weight: .medium)).foregroundStyle(Tw.gray900)
                                    if !f.摘要.isEmpty {
                                        Text(f.摘要).font(.system(size: 12)).foregroundStyle(Tw.gray400)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("删掉这一份", role: .destructive) { Task { await 删(f) } }
                            }
                        }
                    }.listStyle(.insetGrouped)
                }
            }
            .navigationTitle("记忆 · \(cat)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关掉") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button { ballMode.toggle() } label: {
                            Image(systemName: ballMode ? "list.bullet" : "circle.grid.cross")
                        }
                        Button { newOpen = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Tw.gray400)
                        TextField("搜一下它记得的事", text: $q)
                            .font(.system(size: 14))
                    }
                    .padding(10).background(Tw.gray100).clipShape(RoundedRectangle(cornerRadius: 10))
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(MemAPI.类别, id: \.self) { c in
                                Button {
                                    cat = c
                                } label: {
                                    Text(c).font(.system(size: 12.5))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(c == cat ? Tw.gray900 : Tw.gray100)
                                        .foregroundStyle(c == cat ? .white : Tw.gray400)
                                        .clipShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.top, 6)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("看谁的").font(.system(size: 12)).foregroundStyle(Tw.gray400)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(roles) { r in
                                Button {
                                    换角色(r.标识)
                                } label: {
                                    Text(r.名字 + (r.n > 0 ? " · \(r.n)" : ""))
                                        .font(.system(size: 14, weight: r.标识 == charId ? .bold : .regular))
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(r.标识 == charId ? Tw.gray900 : Tw.gray100)
                                        .foregroundStyle(r.标识 == charId ? .white : Tw.gray400)
                                        .clipShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
                .background(Tw.white)
            }
            .task { await 加载角色(); await 加载() }
            .sheet(item: $openFile) { f in 原件页(f) }
            .sheet(isPresented: $newOpen) { 新建页 }
        }
    }

    @ViewBuilder
    private func 原件页(_ f: MemAPI.File) -> some View {
        NavigationStack {
            Group {
                if let d = detail {
                    TextEditor(text: $editText)
                        .font(.system(size: 15))
                        .padding(12)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(f.名)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关掉") { openFile = nil } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存") { Task { await 存(f) } }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("撤销上次改动") { Task { await 撤销() } }
                        .font(.system(size: 13)).foregroundStyle(Tw.gray400)
                }
            }
        }
    }

    private var 新建页: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("叫什么", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newText)
                    .font(.system(size: 15))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tw.gray200))
                Text("放进：\(cat)").font(.system(size: 12)).foregroundStyle(Tw.gray400)
                Spacer()
            }.padding(16)
            .navigationTitle("新建记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("算了") { newOpen = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存") { Task { await 新建() } }
                }
            }
        }
    }

    private func 加载角色() async {
        let got = await MemAPI.角色列表()
        roles = got
        // 当前角色不在可选列表里（被撤下/换号）→ 回落到第一只，别停在空柜子上
        if !got.isEmpty && !got.contains(where: { $0.标识 == charId }) {
            charId = got[0].标识
        }
    }

    private func 换角色(_ id: String) {
        guard id != charId else { return }
        charId = id
        openFile = nil; detail = nil       // 别把上一只的文件详情带到这一只
        Task { await 加载() }
    }

    private func 加载() async {
        loading = true
        box = await MemAPI.列(charId, nil)
        loading = false
    }

    private func 打开(_ f: MemAPI.File) async {
        openFile = f
        detail = await MemAPI.读(charId, cat, f.名)
        editText = detail?.正文 ?? ""
    }

    private func 存(_ f: MemAPI.File) async {
        let ok = await MemAPI.动("/api/mem/edit", charId,
                                 ["类别": cat, "名": f.名, "正文": editText])
        note = ok ? "存好了" : "没存上"
        if ok { openFile = nil; await 加载() }
    }

    private func 新建() async {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let ok = await MemAPI.动("/api/mem/write", charId,
                                 ["类别": cat, "名": newName, "正文": newText])
        if ok { newOpen = false; newName = ""; newText = ""; await 加载() }
    }

    private func 删(_ f: MemAPI.File) async {
        _ = await MemAPI.动("/api/mem/delete", charId, ["类别": cat, "名": f.名])
        await 加载()
    }

    private func 撤销() async {
        let ok = await MemAPI.动("/api/mem/undo", charId, [:])
        if ok { openFile = nil; await 加载() }
    }
}
