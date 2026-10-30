import SwiftUI
import UIKit

// MARK: - 把当前画面传回台子
//
// ★★★ 2026-10-30：为什么要这个东西。
//   Windows 上没法像安卓那样 `adb screencap` 截 iPhone：
//   iTunes 的 usbmuxd 拒绝第三方写「配对记录」（错误 183），
//   所以 pymobiledevice3 / libimobiledevice 全都卡在配对那一步。
//   于是改成**让 App 自己截**：设置页「关于」连点 5 下，
//   截当前窗口 → POST 到台子 `/api/diag/shot` → 排查的人直接取图。
//
//   鉴权用**用户本人的票**（X-Still-Ticket），客户端不编任何密钥 ——
//   台子那边认「主人本人」就行（跟 /api/apk/up 同一条规矩）。

enum ShotUploader {

    /// 截当前 key window（整屏，含导航栏/输入框）
    static func grab() -> Data? {
        let scenes = UIApplication.shared.connectedScenes
        guard let win = scenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return nil }

        let size = win.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 2
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            win.drawHierarchy(in: win.bounds, afterScreenUpdates: true)
        }
        return img.pngData()
    }

    /// 传上去。tag 只是给文件起名（settings / home / talk …）
    static func upload(tag: String, done: @escaping (Bool, String) -> Void) {
        guard let data = grab() else {
            done(false, "截不到当前画面")
            return
        }
        guard var url = URL(string: Cfg.baseURL + "/api/diag/shot?tag=" + tag) else {
            done(false, "地址不对")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 20
        req.stillStamp()          // ★ 贴用户的票（只贴 workbuddy.host）
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                if let err {
                    done(false, "传不上去：" + err.localizedDescription)
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                done(code == 200, code == 200 ? "已传回台子（\(data.count / 1024) KB）"
                                              : "台子回了 \(code)")
            }
        }.resume()
    }
}
