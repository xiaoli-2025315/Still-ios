import SwiftUI

/// ★ 2026-11-19：「它记住的」—— 看见/忘掉它记下的小事。
///
/// 数据来自台子 /api/memory/list、/api/memory/forget（只读/删除，不花钱）。
/// Hermes「说三回就记住」一直在跑，但用户从来没入口：记错了没法改。这就是那个入口。
/// ★ 界面只说人话，不出现 uid / 类别 / 证据 这些开发者词。
struct MemorySheet: View {
    let charId: String
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [CatBrain.MemoryLine] = []
    @State private var loading = true
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在读它记住的…").font(.system(size: 13)).foregroundStyle(Tw.gray400)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty {
                    VStack(spacing: 8) {
                        Text("它还没记住什么").font(.system(size: 15, weight: .semibold))
                        Text("多跟它聊几句，它慢慢会记下你的小事。")
                            .font(.system(size: 13)).foregroundStyle(Tw.gray400)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 32)
                } else {
                    List {
                        Section {
                            ForEach(lines, id: \.文字) { m in
                                HStack(spacing: 12) {
                                    Text(m.文字)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Tw.gray900)
                                    Spacer(minLength: 6)
                                    Button("忘掉") {
                                        Task { await 忘掉(m) }
                                    }
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Tw.gray400)
                                }
                            }
                        } header: {
                            Text("这些都是它自己记下的小事，点「忘掉」它就不再提。")
                                .font(.system(size: 12))
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("它记住的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(Tw.accent.opacity(0.92)))
                        .foregroundStyle(.white)
                        .padding(.bottom, 16)
                        .transition(.opacity)
                }
            }
        }
        .task { await 载入() }
    }

    private func 载入() async {
        loading = true
        lines = await CatBrain.memories(char: charId)
        loading = false
    }

    private func 忘掉(_ m: CatBrain.MemoryLine) async {
        let ok = await CatBrain.forget(char: charId, 类别: m.类别, 文字: m.文字)
        note = ok ? "忘掉了" : "没删成，等会儿再试"
        if ok { await 载入() }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        note = ""
    }
}
