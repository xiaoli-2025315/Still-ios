import Foundation
import ImageIO
import UIKit

// MARK: - 一只猫的动作包
//
// 台子 `GET /api/act/charpack?char=<id>` 给的是一个 zip，里面：
//     act.json                        说明书（有哪些动作、多少帧、fps、脚底在哪）
//     acts/<动作名>/f_<动作名>_0000.webp   透明帧，384×216
//
// ★★★ 为什么不把它解压成一千多个文件
//   实测一只猫 12 条动作 = 1192 个 webp、43MB。解成 1192 个小文件，
//   光文件系统就够呛（写入慢、占两份空间、删的时候更慢）。
//   这里**原样留着那个 zip**，只把「中央目录」读进内存当索引，
//   要哪一帧就 seek 过去读那一段。省空间、省一次全量写入，
//   而且删一只猫 = 删一个文件。
//
// ★★★ 台子的包是 ZIP_STORED（不压缩），所以不用解压算法 —— 读到字节就是 webp。
//   万一以后台子改成 deflate，这里的 `method` 会拒掉并如实报错，
//   不会出现「读出来是乱码、画面全黑、看不出原因」那种情况。
//
// ★ 尺寸与脚底：帧是 384×216。`foot` 是**原始帧里的脚底 y 像素**（两百零几），
//   摆放时要按缩放把它对到地面线上，否则猫会浮起来或者陷进地里。

/// 一只装好的猫。所有读取都在调用方线程上同步做 —— 一帧 34KB，
/// 15fps 推进下每帧有 66ms 预算，直接在用时读就够了，不必再开线程。
final class CatPack {

    // MARK: 说明书里的一条动作

    struct Act: Equatable {
        let name: String
        let display: String
        let frames: Int
        let oneshot: Bool
        let category: String
        let fps: Double
        /// 原始帧里的脚底 y（像素）。0 表示说明书没给。
        let foot: Double

        var isPersist: Bool { category == "persist" }
        var isEvent: Bool { category == "event" }
    }

    /// 台子给的角色 id（目录名就是它）
    let id: String
    /// 说明书里的显示名
    let title: String
    let channel: String
    let acts: [Act]

    /// zip 文件
    let zipURL: URL

    /// 动作名 → 这一条的帧表（文件名 → 数据偏移）
    private var index: [String: [String: Entry]] = [:]
    /// 文件名 → 偏移
    private struct Entry { let off: UInt64; let size: UInt64; let method: UInt16 }

    /// 解出来的帧。**必须限量** —— 一帧 331KB，全缓存会吃掉几百兆。
    private let cache = NSCache<NSString, UIImage>()

    // MARK: - 打开

    /// 打开一个已经落到本地的包。说明书读不出来就返回 nil。
    init?(dir: URL) {
        let zip = dir.appendingPathComponent("pack.zip")
        guard FileManager.default.fileExists(atPath: zip.path) else { return nil }
        self.zipURL = zip
        self.id = dir.lastPathComponent

        guard let table = CatPack.readCentralDirectory(zip),
              let manData = table.data(for: "act.json"),
              let man = try? JSONSerialization.jsonObject(with: manData) as? [String: Any]
        else { return nil }

        self.title = (man["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dir.lastPathComponent
        self.channel = (man["channel"] as? String) ?? "free"

        var list: [Act] = []
        for a in (man["acts"] as? [[String: Any]]) ?? [] {
            guard let n = a["name"] as? String, !n.isEmpty else { continue }
            list.append(Act(
                name: n,
                display: (a["display"] as? String) ?? n,
                frames: (a["frames"] as? NSNumber)?.intValue ?? 0,
                oneshot: ((a["oneshot"] as? NSNumber)?.intValue ?? 0) != 0,
                category: (a["category"] as? String) ?? "",
                fps: (a["fps"] as? NSNumber)?.doubleValue ?? 50,
                foot: (a["foot"] as? NSNumber)?.doubleValue ?? 0))
        }
        guard !list.isEmpty else { return nil }
        self.acts = list

        // 只收这只猫自己的动作目录
        var idx: [String: [String: Entry]] = [:]
        for a in list { idx[a.name] = [:] }
        for (name, e) in table.entries {
            // acts/<动作名>/f_<名字>_<号>.webp
            let parts = name.split(separator: "/")
            guard parts.count == 3, parts[0] == "acts" else { continue }
            let act = String(parts[1])
            guard idx[act] != nil else { continue }
            idx[act]?[String(parts[2])] = e
        }
        self.index = idx

        // 一帧 384×216 → 解码后 331KB。给 24 帧 ≈ 8MB，够来回播一段。
        cache.countLimit = 24
    }

    // MARK: - 查

    func act(_ name: String) -> Act? { acts.first { $0.name == name } }

    /// 按名字找一条 —— 找不到时的回落顺序：
    ///   同名 → sit → 任一条 persist（能一直演的）→ 第一条。
    /// ★ 台子上每只猫不一定十二条全齐（用户原话「他 3 个动作也要播放啊」），
    ///   所以**缺了必须能顶上**，不能让小窗空白。
    func fallback(for name: String) -> Act? {
        if let a = act(name) { return a }
        if let a = act("sit") { return a }
        if let a = acts.first(where: { $0.isPersist }) { return a }
        return acts.first
    }

    // MARK: - 取帧

    /// 第 i 帧（会按帧数取模，循环用）
    func image(act: Act, index i: Int) -> UIImage? {
        let n = max(1, act.frames)
        let k = ((i % n) + n) % n
        let key = "\(act.name)#\(k)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let fname = String(format: "f_%@_%04d.webp", act.name, k)
        guard let e = index[act.name]?[fname],
              let data = read(e),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }

        let img = UIImage(cgImage: cg)
        cache.setObject(img, forKey: key)
        return img
    }

    /// 帧图的原始像素尺寸（用来算缩放）。抽不到就给 384×216 这个已知值。
    var frameSize: CGSize {
        for a in acts {
            if let img = image(act: a, index: 0) { return img.size }
        }
        return CGSize(width: 384, height: 216)
    }

    // MARK: - 读 zip

    private func read(_ e: Entry) -> Data? {
        guard e.method == 0 else { return nil }   // 只认「不压缩」（台子就是这种）
        guard let fh = try? FileHandle(forReadingFrom: zipURL) else { return nil }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: e.off)
            guard let head = try fh.read(upToCount: 30), head.count == 30,
                  head.u32(0) == 0x04034b50 else { return nil }
            let nameLen = UInt64(head.u16(26))
            let extraLen = UInt64(head.u16(28))
            try fh.seek(toOffset: e.off + 30 + nameLen + extraLen)
            guard let d = try fh.read(upToCount: Int(e.size)), d.count == Int(e.size) else { return nil }
            return d
        } catch { return nil }
    }

    /// 中央目录 = zip 的索引。从文件尾往前找 EOCD，再顺着条目走一遍。
    private struct DirTable {
        var entries: [String: Entry] = [:]
        var zipURL: URL = URL(fileURLWithPath: "/dev/null")
        func data(for name: String) -> Data? {
            guard let e = entries[name], e.method == 0,
                  let fh = try? FileHandle(forReadingFrom: zipURL) else { return nil }
            defer { try? fh.close() }
            do {
                try fh.seek(toOffset: e.off)
                guard let head = try fh.read(upToCount: 30), head.count == 30 else { return nil }
                let nl = UInt64(head.u16(26)), el = UInt64(head.u16(28))
                try fh.seek(toOffset: e.off + 30 + nl + el)
                return try fh.read(upToCount: Int(e.size))
            } catch { return nil }
        }
    }

    /// 从某个偏移读一段。
    /// ★ `FileHandle.read(from:length:)` 只有 macOS 有，iOS 上没有 ——
    ///   第一版用了它，CI 直接报 "extra arguments at positions #1, #2"。
    ///   iOS 上只能 seek + read(upToCount:)。
    private static func readAt(_ fh: FileHandle, at off: UInt64, len: Int) -> Data? {
        guard len > 0 else { return Data() }
        do {
            try fh.seek(toOffset: off)
            return try fh.read(upToCount: len)
        } catch { return nil }
    }

    private static func readCentralDirectory(_ url: URL) -> DirTable? {
        guard let fh = try? FileHandle(forReadingFrom: url),
              let end = try? fh.seekToEnd() else { return nil }
        defer { try? fh.close() }

        // EOCD 在最后 22 字节起，可能带最多 64KB 注释 —— 往回找签名
        let tailLen: UInt64 = min(end, 66560)
        guard let tail = Self.readAt(fh, at: end - tailLen, len: Int(tailLen)) else { return nil }

        var eocd: Int? = nil
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { return nil }

        let count = Int(tail.u16(e + 10))
        let cdSize = UInt64(tail.u32(e + 12))
        let cdOff = UInt64(tail.u32(e + 16))
        guard cdOff + cdSize <= end, let cd = Self.readAt(fh, at: cdOff, len: Int(cdSize)) else { return nil }

        var t = DirTable()
        t.zipURL = url
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, cd.u32(p) == 0x02014b50 else { break }
            let method = cd.u16(p + 10)
            let comp = UInt64(cd.u32(p + 20))
            let nameLen = Int(cd.u16(p + 28))
            let extraLen = Int(cd.u16(p + 30))
            let cmtLen = Int(cd.u16(p + 32))
            let localOff = UInt64(cd.u32(p + 42))
            guard p + 46 + nameLen <= cd.count else { break }
            let name = String(data: cd.subdata(in: (p + 46)..<(p + 46 + nameLen)), encoding: .utf8) ?? ""
            if !name.isEmpty, method <= 8 {
                t.entries[name] = Entry(off: localOff, size: comp, method: method)
            }
            p += 46 + nameLen + extraLen + cmtLen
        }
        return t.entries.isEmpty ? nil : t
    }
}

// MARK: - 小工具：按小端读字节

private extension Data {
    func u16(_ i: Int) -> UInt16 {
        guard i + 2 <= count else { return 0 }
        return UInt16(self[startIndex + i]) | (UInt16(self[startIndex + i + 1]) << 8)
    }
    func u32(_ i: Int) -> UInt32 {
        guard i + 4 <= count else { return 0 }
        return UInt32(self[startIndex + i])
            | (UInt32(self[startIndex + i + 1]) << 8)
            | (UInt32(self[startIndex + i + 2]) << 16)
            | (UInt32(self[startIndex + i + 3]) << 24)
    }
}

// MARK: - 装到手机上的猫（存哪、正在用哪只）

/// 一只猫的全部本地状态：目录、包、下载进度。
@MainActor
final class CatPackStore: ObservableObject {

    static let shared = CatPackStore()

    /// 下载进度 0…1（不是正在下就是 nil）
    @Published private(set) var progress: Double?
    /// 正在下的是哪只
    @Published private(set) var downloading: String?
    /// 正在用的那只（nil = App 自带那只）
    @Published private(set) var current: CatPack?

    private static let keyCurrent = "still.catpack.current"

    var root: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cats", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    private init() {
        if let id = UserDefaults.standard.string(forKey: Self.keyCurrent), !id.isEmpty {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            if let p = CatPack(dir: dir) {
                current = p
            } else {
                // ★ 包在、但读不出来（下到一半、被系统清过）——
                //   别让 App 一直用一只读不出来的猫，直接回退到自带的。
                UserDefaults.standard.removeObject(forKey: Self.keyCurrent)
            }
        }
    }

    func dir(of id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    /// 这只已经在本地了没有
    func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: dir(of: id).appendingPathComponent("pack.zip").path)
    }

    /// 本地已经打开的包（不再重读 zip 索引）
    func installed(_ id: String) -> CatPack? {
        if let c = current, c.id == id { return c }
        guard isInstalled(id) else { return nil }
        return CatPack(dir: dir(of: id))
    }

    // MARK: - 下

    /// 把这只猫的动作包下下来。
    /// - Returns: 装好、可以马上用的包；失败抛错。
    /// - 已经有了就直接返回，不重复下 43MB。
    func install(charId: String, force: Bool = false) async throws -> CatPack {
        if !force, let p = installed(charId) { return p }

        let d = dir(of: charId)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)

        progress = 0
        downloading = charId

        defer {
            progress = nil
            downloading = nil
        }

        var comp = URLComponents(string: ActLab.base + "/api/act/charpack")!
        comp.queryItems = [URLQueryItem(name: "char", value: charId)]
        var req = URLRequest(url: comp.url!)
        // 43–63MB，给足时间；不要让它 20 秒就放弃
        req.timeoutInterval = 300

        let (tmp, resp) = try await Self.fetchFile(req) { [weak self] f in
            Task { @MainActor in self?.progress = f }
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ActLab.LabError("台子没给包（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)）")
        }

        // 先落到临时的，成功了再换上去 —— 中途断网不会留下半个坏包
        let dst = d.appendingPathComponent("pack.zip")
        let part = d.appendingPathComponent("pack.part")
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: tmp, to: part)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: part, to: dst)

        guard let pack = CatPack(dir: d) else {
            // 包在但读不出来：删掉，别留个坏东西占着 40MB
            try? FileManager.default.removeItem(at: d)
            throw ActLab.LabError("下下来的包读不出来（说明书缺失或格式不对）")
        }
        return pack
    }

    // MARK: - 换

    /// 换到这只。nil = 换回 App 自带那只。
    func use(_ pack: CatPack?) {
        current = pack
        if let p = pack {
            UserDefaults.standard.set(p.id, forKey: Self.keyCurrent)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.keyCurrent)
        }
        // 换猫 = 画面源变了，帧泵要重新准备底图和动作表
        PiPController.shared?.catSwitched()
    }

    func isCurrent(_ id: String) -> Bool { current?.id == id }

    /// 删掉一只（腾空间）。正在用的那只不许删，调用方先换走。
    func remove(_ id: String) {
        guard !isCurrent(id) else { return }
        try? FileManager.default.removeItem(at: dir(of: id))
    }

    /// 本地占了多少
    func usedBytes() -> Int64 {
        var total: Int64 = 0
        if let es = try? FileManager.default.contentsOfDirectory(at: root,
                                                                includingPropertiesForKeys: [.fileSizeKey]) {
            for e in es {
                let f = e.appendingPathComponent("pack.zip")
                if let s = try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int64 {
                    total += s
                }
            }
        }
        return total
    }

    // MARK: - 下载一个文件（带进度）
    //
    // ★ 为什么不用 `URLSession.shared.download(for:)` 那个 async 版：
    //   它拿不到下载进度，40 多兆的东西没有进度条，用户只会以为卡死了。
    //   这里用老的 `downloadTask` + 定时读 `task.progress`，两样都能拿到。
    // ★ 回调给的那个临时文件**一返回就被系统删掉**，必须当场搬走。
    private static func fetchFile(_ req: URLRequest,
                                  onProgress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let task = URLSession.shared.downloadTask(with: req) { url, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                guard let url, let resp else {
                    cont.resume(throwing: ActLab.LabError("没接到台子的回话"))
                    return
                }
                let keep = FileManager.default.temporaryDirectory
                    .appendingPathComponent("stillpack-\(UUID().uuidString).part")
                do {
                    try? FileManager.default.removeItem(at: keep)
                    try FileManager.default.moveItem(at: url, to: keep)
                    cont.resume(returning: (keep, resp))
                } catch {
                    cont.resume(throwing: error)
                }
            }
            // 进度轮询：任务一结束自己退出（state 不再是 running）
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if task.state != .running { break }
                    let f = task.progress.fractionCompleted
                    if f > 0 { onProgress(f) }
                }
            }
            task.resume()
        }
    }
}
