// 方向自检：证明小窗里那只猫到底是正着还是倒着。
//
// 为什么要有这个：这只猫"倒过来"已经反复出过四次（v41/v47 两次/v51/v52 第一版），
// 每次都靠肉眼在真机上判，判错就白编一轮 —— v52 第一版就是这么被它自己拦下的。
//
// 做法：造一张「上红下蓝」的图，走一遍跟 LiveFramePump.compose **完全相同的**
//      像素缓冲 / 上下文参数 / 翻转，然后把内存里第 0 行（= 画面顶部）的像素读回来。
//        · 顶部＝红 ⇒ 正立
//        · 顶部＝蓝 ⇒ 倒的
//
// 判据钉死的那一条是 `翻·局部翻` —— 它就是 LiveFramePump.drawUpright 现在干的事。
// 它不正立，CI 直接失败、不出包，绝不把倒着的猫发到他手机上。
//
// 跑法：swift Tools/flipcheck/main.swift      （macOS，CI 每次编译前都跑）

import Foundation
import CoreGraphics
import CoreVideo

let S = 200

func makeTestImage() -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    // 原生位图上下文：原点左下、y 朝上 ⇒ y 从 0 到 S/2 是「画面下半」
    let raw = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                        bytesPerRow: S * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)!
    raw.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    raw.fill(CGRect(x: 0, y: 0, width: S, height: S))
    raw.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    raw.fill(CGRect(x: 0, y: 0, width: S, height: S / 2))
    return raw.makeImage()!
}

/// 跟 LiveFramePump.compose 里的三条路一一对应。
enum Mode: String {
    case 不翻_直接贴 = "上下文不翻 + 直接贴"
    case 翻_直接贴   = "上下文翻成 y 朝下 + 直接贴"
    case 翻_局部翻   = "上下文翻成 y 朝下 + 局部翻（← drawUpright 现在走这条）"
}

func compose(_ img: CGImage, _ mode: Mode) -> CVPixelBuffer? {
    var pbOut: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, S, S,
                              kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &pbOut) == kCVReturnSuccess,
          let pb = pbOut else { return nil }

    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb),
          let ctx = CGContext(data: base, width: S, height: S,
                              bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

    let full = CGRect(x: 0, y: 0, width: CGFloat(S), height: CGFloat(S))

    if mode == .不翻_直接贴 {
        ctx.draw(img, in: full)
        return pb
    }

    // 跟 compose 一样：先把上下文翻成 y 朝下（原点左上）
    ctx.translateBy(x: 0, y: CGFloat(S))
    ctx.scaleBy(x: 1, y: -1)

    if mode == .翻_直接贴 {
        ctx.draw(img, in: full)
    } else {
        // 跟 drawUpright 一字不差
        ctx.saveGState()
        ctx.translateBy(x: 0, y: full.minY + full.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: full)
        ctx.restoreGState()
    }
    return pb
}

/// 读 CVPixelBuffer 第 `row` 行中间那个像素，返回 (r,g,b)。行 0 = 画面顶部。
func pixel(_ pb: CVPixelBuffer, row: Int) -> (Int, Int, Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let p = CVPixelBufferGetBaseAddress(pb)!.advanced(by: row * bpr + (S / 2) * 4)
        .assumingMemoryBound(to: UInt8.self)
    // 32BGRA little-endian：内存顺序 B,G,R,A
    return (Int(p[2]), Int(p[1]), Int(p[0]))
}

let img = makeTestImage()
var 实际那条正立 = false

print("测试图：上红(255,0,0) 下蓝(0,0,255)；读内存第 0 行＝画面顶部\n")

for mode in [Mode.不翻_直接贴, .翻_直接贴, .翻_局部翻] {
    guard let pb = compose(img, mode) else {
        print("!! 建缓冲失败：\(mode.rawValue)")
        exit(2)
    }
    let top = pixel(pb, row: 0)
    let bottom = pixel(pb, row: S - 1)
    let 正立 = top.0 > 128 && top.2 < 128

    print("""
    ── \(mode.rawValue)
       顶部 RGB = \(top)   底部 RGB = \(bottom)
       ⇒ \(正立 ? "正立 ✅" : "倒过来 ❌")
    """)

    if mode == .翻_局部翻 { 实际那条正立 = 正立 }
}

if 实际那条正立 {
    print("\n结论：✅ drawUpright 现在这条（上下文翻 + 局部翻）就是正立的。")
    exit(0)
} else {
    print("\n结论：❌ 小窗里的猫会倒过来 —— drawUpright 的翻转方向不对，别出包。")
    exit(1)
}
