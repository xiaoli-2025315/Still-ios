import SwiftUI

// MARK: - 圆窗专用：按「指定那只角色」播自己的完整帧包
//
// ★★★ 2026-11-21（对齐安卓 OrbPetView）：
//   主页展示框、聊天页浮宠都读 `CatPackStore.shared.current`（主页选中的那只），
//   光换动作段不换角色 ⇒ 跟谁聊都播主页那只。安卓那边就是栽在这、3.92 才修。
//   iOS 顶栏原来走 GifView（抽帧 GIF）按 orbCharId 取，其实已经"谁的播谁"，
//   但播的是抽帧预告、不是完整帧。这里两者合一：
//     · 按传入的 charId 取**那只自己的**包（installed / builtin），不读 current；
//     · 用 PackCatView 逐帧播完整动作，不编假画面；
//     · 没这只的包就什么都不画，让外层决定露加号还是占位。
//   ★ 跟主页 current 完全隔离 —— 不会为了圆窗把主页/浮宠那只带跑。

@MainActor
struct OrbPet: View {
    let charId: String
    var actName: String = "sit"
    var width: CGFloat = 58

    @ObservedObject private var store = CatPackStore.shared

    /// 这只角色有没有自己的动画可播（给外层判断露不露「创建动态形象」）。
    static func hasFrame(_ id: String) -> Bool {
        let s = CatPackStore.shared
        if let p = s.installed(id), p.acts.first(where: { $0.name == "sit" }) != nil { return true }
        if id == CatPackStore.builtinId, let b = s.builtin, b.acts.first(where: { $0.name == "sit" }) != nil { return true }
        return false
    }

    private var pack: CatPack? {
        if let p = store.installed(charId) { return p }
        if charId == CatPackStore.builtinId { return store.builtin }
        return nil
    }

    var body: some View {
        Group {
            if let p = pack {
                PackCatView(pack: p, width: width, actName: actName)
            } else {
                Color.clear
            }
        }
    }
}
