import SwiftUI

// MARK: - 聊天记录搜索（2026-11-24）
//
// 从单聊 / 群聊设置卡进入，只搜「当前这个对话框」的记录。
// · 顶部搜索框 + 常用词一点就搜
// · 结果：谁说的 / 什么时候 / 原文（命中词高亮）/ 前后一句
// · 点一条 → 回聊天页滚到那条并短暂高亮
// 数据取 ChatLog.all(ch:) —— 写入端已按会话号分开，老记录 ch="" 也带上不丢。

struct ChatSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let ch: String
    let title: String
    /// 点结果：把这条记录的 id 回给聊天页定位
    var onPick: (String) -> Void = { _ in }

    @State private var kw = ""
    private var rows: [ChatLog.Row] { ChatLog.all(ch: ch) }
    private var hits: [ChatLog.Row] {
        let k = kw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return [] }
        return rows.filter { $0.you.contains(k) || $0.cat.contains(k) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：返回 + 搜索框
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20))
                        .foregroundStyle(Tw.gray600)
                        .frame(width: 30)
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(Tw.gray400)
                    TextField("搜聊天记录里的关键词", text: $kw)
                        .font(.system(size: 14))
                        .foregroundStyle(Tw.gray900)
                    if !kw.isEmpty {
                        Button { kw = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Tw.gray400)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 20).fill(Tw.gray100))
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Text(kw.isEmpty ? "在和「\(title)」的对话里搜 · 输入关键词"
                            : "找到 \(hits.count) 条 · 点一条跳到那条消息")
                .font(.system(size: 11))
                .foregroundStyle(Tw.gray400)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            if kw.isEmpty {
                // 常用词
                HStack(spacing: 8) {
                    ForEach(["忙", "猫", "想你"], id: \.self) { w in
                        Button { kw = w } label: {
                            Text(w).font(.system(size: 12)).foregroundStyle(Tw.gray600)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Tw.gray100))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(Tw.gray300)
                    Text("输入词后，列出这条对话里所有包含它的消息")
                        .font(.system(size: 12)).foregroundStyle(Tw.gray400)
                }
                Spacer()
            } else if hits.isEmpty {
                Spacer()
                Text("没有找到，换个词试试")
                    .font(.system(size: 13)).foregroundStyle(Tw.gray400)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(hits) { r in
                            结果卡(r)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
        }
        .background(Tw.white.ignoresSafeArea())
    }

    private func 结果卡(_ r: ChatLog.Row) -> some View {
        let 我说 = r.you.contains(kw)
        let 原文 = 我说 ? r.you : r.cat
        let 谁 = r.sp.isEmpty ? (我说 ? "我" : title) : r.sp
        let 前后 = 我说 ? r.cat : r.you
        return Button {
            onPick(r.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(谁).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tw.gray600)
                    Spacer()
                    Text(时间话(r.at)).font(.system(size: 11)).foregroundStyle(Tw.gray400)
                }
                Text(高亮(原文, kw))
                    .font(.system(size: 13)).foregroundStyle(Tw.gray900)
                    .fixedSize(horizontal: false, vertical: true)
                if !前后.isEmpty {
                    Text("前后：\(前后)")
                        .font(.system(size: 10.5)).foregroundStyle(Tw.gray400)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(Tw.white)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tw.gray200, lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func 高亮(_ s: String, _ kw: String) -> AttributedString {
        var a = AttributedString(s)
        var from = s.startIndex
        while let at = s.range(of: kw, range: from..<s.endIndex) {
            if let lo = AttributedString.Index(at.lowerBound, within: a),
               let hi = AttributedString.Index(at.upperBound, within: a) {
                a[lo..<hi].backgroundColor = Color(red: 1, green: 0.91, blue: 0.66)
            }
            from = at.upperBound
            if from == s.endIndex { break }
        }
        return a
    }

    private func 时间话(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }
}
