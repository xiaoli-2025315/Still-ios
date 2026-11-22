import SwiftUI

// MARK: - 聊天输入框样式（对齐安卓 A/B/C/D 四档）
//
// ★★★ 2026-11-21：安卓在「设置 → 其他 → 聊天输入框」能切四种壳。
//   iOS 这边照搬：同一个 key 两端各读各写（安卓 still_ui.xml、iOS UserDefaults，
//   不互通也无妨 —— 各端记住自己选的即可）。
//   0 = A 整体方框 / 1 = B 全胶囊 / 2 = C 灰底圆条 / 3 = D 双层卡。
//   ★ 只换「壳」（圆角 / 底色 / 描边），不动输入、发送、语音任何交互 ——
//     这样四种看得见地不同，又不碰已经调顺的键盘与录音链路。

enum ComposerStyle {
    static let key = "still.composer.style"
    static let names = ["A 整体方框", "B 全胶囊", "C 灰底圆条", "D 双层卡"]

    /// 壳底色：A/B/D 白、C 浅灰底（iPhone 信息那种）。
    static func fill(_ style: Int) -> Color {
        style == 2 ? Tw.gray100 : Tw.white
    }

    /// 圆角：A=12 方一点、B=胶囊、C=18、D=16。
    static func radius(_ style: Int) -> CGFloat {
        switch style {
        case 0: return 12
        case 1: return 999      // Capsule
        case 2: return 18
        default: return 16      // D 双层卡
        }
    }

    /// 要不要描边：A/D 描边，B 轻描边，C 灰底不描边。
    static func stroke(_ style: Int) -> Color? {
        switch style {
        case 2: return nil
        case 1: return Tw.gray200
        default: return Tw.gray300
        }
    }
}
