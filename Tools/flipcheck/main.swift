// 方向自检：证明「合成上下文翻一次之后，ctx.draw 直接贴 = 正立」。
//
// 为什么要有这个：小窗里那只猫"倒过来"已经反复出过三次（v47 两次 + v51），
// 每次都靠肉眼在真机上判，判错就白编一轮。这条脚本把方向钉成数字：
// 造一张「上红下蓝」的图，走一遍 LiveFramePump.compose 用的**完全相同的**
// 像素缓冲 / 上下文参数 / 翻转，然后把内存里第 0 行（= 画面顶部）的像素读回来。
//   · 顶部是红 ⇒ PASS，直接贴是正的
//   · 顶部是蓝 ⇒ FAIL，说明还得再翻
//
// 跑法：swift Tools/flipcheck/main.swift   （macOS，CI 里也跑一遍）

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

/// 把图贴进一个 32BGRA 的 CVPixelBuffer，`flip` 决定要不要像 compose 那样先把上下文翻成 y 朝下。
func compose(_ img: CGImage, flip: Bool) -> CVPixelBuffer? {
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

    if flip {
        ctx.translateBy(x: 0, y: CGFloat(S))
        ctx.scaleBy(x: 1, y: -1)
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(S), height: CGFloat(S)))
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
var failed = false

for flip in [true, false] {
    guard let pb = compose(img, flip: flip) else {
        print("!! 建缓冲失败 flip=\(flip)")
        exit(2)
    }
    let top = pixel(pb, row: 0)
    let bottom = pixel(pb, row: S - 1)
    let 正立 = top.0 > 128 && top.2 < 128

    print("""
    ── 上下文翻成 y 朝下 = \(flip)
       顶部像素 RGB = \(top)   （应该是红 255,0,0）
       底部像素 RGB = \(bottom)（应该是蓝 0,0,255）
       判定：\(正立 ? "正立 ✅" : "倒过来 ❌")
    """)

    // 我们实际用的那条路：翻一次 + 直接 draw。它必须正立。
    if flip && !正立 { failed = true }
}

if failed {
    print("\n结论：❌ 小窗里的猫会倒过来 —— 合成上下文之外还需要再翻一次，别直接贴。")
    exit(1)
} else {
    print("\n结论：✅ 「上下文翻一次 + ctx.draw 直接贴」就是正立的，不需要任何额外翻转/开关。")
    exit(0)
}
