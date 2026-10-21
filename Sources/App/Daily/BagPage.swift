import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 猫的背包
//
// 安卓那边这一页收的是「别人扔给它的东西」：文件、图片，都能在这儿看、存到手机、删掉。
// iOS 这版做成同一个东西：从「文件」里挑进来 → 留在 App 里 → 能看、能分享、能存相册、能删。
//
// ★ 为什么不做「接收 AirDrop 直接进背包」：那要把 App 注册成文件接收方（Info.plist 里
//   声明 CFBundleDocumentTypes + LSSupportsOpeningDocumentsInPlace），
//   会让「还在」出现在所有文件的「打开方式」里 —— 这个代价先不付。
//   现在这条（从文件里挑）人人能用，功能一样。

@MainActor
final class BagModel: ObservableObject {

    @Published var files: [Item] = []
    @Published var err: String?
    @Published var note = ""

    struct Item: Identifiable, Equatable {
        let url: URL
        var id: String { url.lastPathComponent }
        var name: String { url.lastPathComponent }

        var size: String {
            let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if n > 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
            return "\(max(1, n / 1024)) KB"
        }

        var isImage: Bool {
            ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(url.pathExtension.lowercased())
        }
    }

    var root: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bag", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    func load() {
        let fm = FileManager.default
        let list = (try? fm.contentsOfDirectory(at: root,
                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                               options: [.skipsHiddenFiles])) ?? []
        files = list
            .filter { !$0.hasDirectoryPath }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
            .map { Item(url: $0) }
    }

    func add(from src: URL) {
        let fm = FileManager.default
        // 从「文件」里挑来的东西在别的进程里，要先要一份访问权
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        var dst = root.appendingPathComponent(src.lastPathComponent)
        if fm.fileExists(atPath: dst.path) {
            let base = src.deletingPathExtension().lastPathComponent
            let ext = src.pathExtension
            dst = root.appendingPathComponent("\(base)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        }
        do {
            try fm.copyItem(at: src, to: dst)
            note = "收进背包了：\(dst.lastPathComponent)"
            load()
        } catch {
            err = "没放进背包：\(error.localizedDescription)"
        }
    }

    func delete(_ item: Item) {
        do {
            try FileManager.default.removeItem(at: item.url)
            load()
            note = "删掉了"
        } catch {
            err = "删不掉：\(error.localizedDescription)"
        }
    }

    func saveToAlbum(_ item: Item) {
        guard let data = try? Data(contentsOf: item.url), let img = UIImage(data: data) else {
            err = "这个不是图片，存不了相册（可以用分享）"
            return
        }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        note = "存进相册了"
    }
}

@MainActor
struct BagPage: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BagModel()
    @State private var importing = false
    @State private var preview: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.note.isEmpty || model.err != nil {
                Text(model.err ?? model.note)
                    .font(.system(size: 11))
                    .foregroundStyle(model.err == nil ? Tw.gray500 : Tw.red600)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if model.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bag")
                        .font(.system(size: 30))
                        .foregroundStyle(Tw.gray300)
                    Text("背包是空的")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tw.gray600)
                    Text("把别人给它的东西挑进来，它就替你收着。")
                        .font(.system(size: 11))
                        .foregroundStyle(Tw.gray400)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.files) { f in
                            row(f)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }

            Button {
                importing = true
            } label: {
                Text("往背包里放东西")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Tw.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(Tw.red600)
                    )
            }
            .buttonStyle(PressStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Tw.gray50.ignoresSafeArea())
        .task { model.load() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for u in urls { model.add(from: u) }
            case .failure(let e):
                model.err = "没挑成：\(e.localizedDescription)"
            }
        }
        .sheet(item: Binding(get: { preview.map { PreviewTarget(url: $0) } },
                             set: { if $0 == nil { preview = nil } })) { t in
            QuickLookPage(url: t.url)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tw.gray500)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tw.gray100))
            }
            .buttonStyle(PressStyle(scale: 0.9))

            VStack(alignment: .leading, spacing: 1) {
                Text("猫的背包")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Tw.gray900)
                Text("\(model.files.count) 样东西 · 点开能看")
                    .font(.system(size: 11))
                    .foregroundStyle(Tw.gray400)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func row(_ f: BagModel.Item) -> some View {
        Button {
            preview = f.url
        } label: {
            HStack(spacing: 11) {
                thumb(f)
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tw.gray900)
                        .lineLimit(1)
                    Text("\(f.url.pathExtension.uppercased()) · \(f.size)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tw.gray400)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tw.gray300)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Tw.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Tw.gray200, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PressStyle())
        .contextMenu {
            ShareLink(item: f.url) { Label("分享出去", systemImage: "square.and.arrow.up") }
            if f.isImage {
                Button {
                    model.saveToAlbum(f)
                } label: {
                    Label("存到相册", systemImage: "photo")
                }
            }
            Button(role: .destructive) {
                model.delete(f)
            } label: {
                Label("删掉", systemImage: "trash")
            }
        }
    }

    private func thumb(_ f: BagModel.Item) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Tw.gray100)
                .frame(width: 44, height: 44)
            if f.isImage, let d = try? Data(contentsOf: f.url), let img = UIImage(data: d) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Tw.gray400)
            }
        }
    }
}

struct PreviewTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct QuickLookPage: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let v = QLPreviewController()
        v.dataSource = context.coordinator
        return v
    }

    func updateUIViewController(_ v: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coord { Coord(url: url) }

    final class Coord: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
