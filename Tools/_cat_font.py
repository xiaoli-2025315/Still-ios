#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
把毛毡猫做成「会动的组件画面」。

背景（为什么必须绕这么大一圈）：
------------------------------------------------------------------
WidgetKit 明说组件里**不能播视频、不能播动图**，timeline 换图最快也只有约 5 秒/张。
组件里唯一「由系统每秒自更新、不重跑代码、不吃刷新额度」的东西是
`Text(timerInterval:)` —— 它每秒把显示的文字改一次。

于是唯一的连续动画路径就是：
    把「猫的每一帧」画成**字体的一个字形**，
    再用 `Text(timerInterval:)` 去驱动它，让它每秒翻一页。

字体格式选 **sbix**：这是 Apple 自家的彩色位图字体表（Apple Color Emoji 就是它），
iOS 100% 认；字形里直接塞 PNG，不用把猫转成矢量轮廓，颜色和质感都能保住。

本脚本做两件事：
    frames  重绘本 App 那只矢量猫，输出 10 帧 PNG（姿势：坐姿，尾巴在摆）
    font    把 10 帧塞进一个 sbix 字体（字符 '0'..'9' 各对应一帧）

用法：
    python Tools/_cat_font.py              # 两件事都做
    python Tools/_cat_font.py frames       # 只出帧（快速看效果）
    python Tools/_cat_font.py sheet        # 出帧 + 拼一张预览图

★ 几何参数全部照抄 Sources/App/Cat/CatView.swift 的 `pose == .sit` 那一行，
  和 App 里那只**必须一模一样**，否则组件里的猫和 App 里的猫是两只猫。
"""

import math
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT_FRAMES = os.path.join(ROOT, "Tools", "out", "cat_frames")
OUT_FONT = os.path.join(ROOT, "Resources", "fonts", "StillFrames.ttf")

N_FRAMES = 10          # 10 帧 ↔ 数字 0..9，正好对上计时器每秒翻一位
BW, BH = 256, 224      # 位图尺寸。200:175 = 256:224，和 CatView 的逻辑比例一致
S = 6                  # 超采样倍率（先画大再缩小 = 抗锯齿）

# 颜色，逐条来自 CatView.swift 的 CatColor
C_BODY = (0xE3, 0xD3, 0xC3)
C_BODY_DARK = (0xD3, 0xBF, 0xA9)
C_PATCH = (0xC9, 0x7B, 0x4E)
C_EAR = (0xE8, 0xB4, 0xA0)
C_LINE = (0x6B, 0x5D, 0x50)
C_NOSE = (0xC9, 0x7B, 0x4E)
C_EYE = (0x4A, 0x3F, 0x35)


# ---------------------------------------------------------------- 几何工具

def px(x, y):
    """逻辑坐标（CatView 的 200x175）→ 画布像素坐标。"""
    return (x * S, y * S)


def cubic(p0, p1, p2, p3, n=48):
    out = []
    for i in range(n + 1):
        t = i / n
        m = 1 - t
        x = m * m * m * p0[0] + 3 * m * m * t * p1[0] + 3 * m * t * t * p2[0] + t * t * t * p3[0]
        y = m * m * m * p0[1] + 3 * m * m * t * p1[1] + 3 * m * t * t * p2[1] + t * t * t * p3[1]
        out.append((x, y))
    return out


def quad(p0, p1, p2, n=32):
    out = []
    for i in range(n + 1):
        t = i / n
        m = 1 - t
        x = m * m * p0[0] + 2 * m * t * p1[0] + t * t * p2[0]
        y = m * m * p0[1] + 2 * m * t * p1[1] + t * t * p2[1]
        out.append((x, y))
    return out


def ebox(cx, cy, rx, ry_logical):
    """椭圆包围盒（逻辑坐标矩形 → 画布像素矩形）。

    注意：CatView 里的 rx 是按 200 宽算的、ry 是按「高度」算的，
    两者缩放系数相同（k = width/200），所以这里统一用 S 就行；
    但 CatPose 的 ry 是**半径**，调用方传进来已经是半径。
    """
    return [cx * S - rx * S, cy * S - ry_logical * S, cx * S + rx * S, cy * S + ry_logical * S]


def stroke_polyline(draw, pts, color, w):
    """折线描边 + 两端补圆（PIL 的 line 没有 linecap）。"""
    pts = [px(*p) for p in pts]
    draw.line(pts, fill=color, width=int(round(w)), joint="curve")
    r = w / 2.0
    for p in (pts[0], pts[-1]):
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=color)


# ---------------------------------------------------------------- 姿势（= CatView 的 .sit）

RY0 = 34.0          # 身体半高
HEAD_CY0 = 58.0     # 头心 y
HEAD_R = 30.0       # 头半径
EAR0 = 0.0          # 耳朵旋转角
PAW_Y = 142.0       # 爪子中心 y

TAIL_LOW = [(146, 116), (176, 110), (180, 84), (161, 75), (151, 70), (142, 77), (147, 88)]
TAIL_HIGH = [(148, 112), (182, 104), (186, 70), (168, 58), (160, 52), (150, 60), (155, 71)]


def tail_points(phase):
    """尾巴的 7 个控制点。

    phase ∈ [0,1)：0 = 垂着，0.5 = 举到最高，回到 1 = 又垂下来。
    ★ 根部少动、尾尖多动（k/6 加权）—— 不然整条尾巴像根棍子整体抬。
    """
    s = (math.sin(phase * 2 * math.pi - math.pi / 2) + 1) / 2.0   # 0 → 1 → 0
    pts = []
    for k, (b, u) in enumerate(zip(TAIL_LOW, TAIL_HIGH)):
        f = s * (0.30 + 0.70 * (k / 6.0))
        pts.append((b[0] + (u[0] - b[0]) * f, b[1] + (u[1] - b[1]) * f))
    return pts


def draw_cat(phase):
    """按相位画一整只猫，返回超采样后的 RGBA 图。"""
    W, H = 200 * S, 175 * S
    img = Image.new("RGBA", (int(W), int(H)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    lw = 1.7 * S          # 主线宽（CatView: 1.7 * k）
    lw_thin = 1.5 * S
    lw_hair = 1.2 * S

    # 呼吸：身体半高和头心都随相位微微起伏（幅度很小，只是让它「活着」）
    breath = math.sin(phase * 2 * math.pi - math.pi / 2)
    ry = RY0 + 1.3 * breath
    head_cy = HEAD_CY0 + 1.0 * breath

    # ---- 1. 尾巴（最底层）------------------------------------------------
    tp = tail_points(phase)
    curve = cubic(tp[0], tp[1], tp[2], tp[3]) + cubic(tp[3], tp[4], tp[5], tp[6])[1:]
    poly = [px(*p) for p in curve]
    d.polygon(poly, fill=C_BODY_DARK)                       # 填充
    pts_px = [px(*p) for p in curve]
    d.line(pts_px, fill=C_LINE, width=int(round(lw)), joint="curve")
    for p in (pts_px[0], pts_px[-1]):                       # 圆头
        rr = lw / 2.0
        d.ellipse([p[0] - rr, p[1] - rr, p[0] + rr, p[1] + rr], fill=C_LINE)

    # ---- 2. 身体 ---------------------------------------------------------
    body = ebox(100, 112, 50, ry)
    d.ellipse(body, fill=C_BODY, outline=C_LINE, width=int(round(lw)))

    # 背上那块赤陶色斑（一个闭合的二次贝塞尔，opacity 0.28）
    patch_y = 112 - ry * 0.42
    patch = ([ (100, patch_y - 26.0) ])  # 起点用下面 move 的那个点
    p_start = (66, patch_y)
    seg1 = quad(p_start, (100, patch_y - 13), (134, patch_y))
    seg2 = quad((134, patch_y), (126, patch_y + 17), (100, patch_y + 17))
    seg3 = quad((100, patch_y + 17), (74, patch_y + 17), p_start)
    blob = seg1 + seg2[1:] + seg3[1:]
    d.polygon([px(*p) for p in blob], fill=_blend(C_BODY, C_PATCH, 0.28))

    # ---- 3. 爪子 ---------------------------------------------------------
    pxr, pyr = 11.0, 7.0
    for cx_, fill in ((86.0, C_BODY_DARK), (114.0, C_BODY)):
        box = ebox(cx_, PAW_Y, pxr, pyr)
        d.ellipse(box, fill=fill, outline=C_LINE, width=int(round(lw)))

    # ---- 4. 耳朵（整组绕头心旋转 EAR0 度，这里 = 0）-----------------------
    def tri(a, b, c):
        return [a, b, c]

    lo = tri((76, head_cy - 18), (70, head_cy - 44), (94, head_cy - 28))
    ro = tri((124, head_cy - 18), (130, head_cy - 44), (106, head_cy - 28))
    li = tri((77, head_cy - 21), (74, head_cy - 37), (88, head_cy - 27))
    ri = tri((123, head_cy - 21), (126, head_cy - 37), (112, head_cy - 27))

    d.polygon([px(*p) for p in lo], fill=C_BODY)
    d.polygon([px(*p) for p in ro], fill=C_BODY)
    d.polygon([px(*p) for p in li], fill=C_EAR)
    d.polygon([px(*p) for p in ri], fill=C_EAR)
    for t in (lo, ro):
        d.line([px(*p) for p in t] + [px(*t[0])], fill=C_LINE,
               width=int(round(lw)), joint="curve")

    # ---- 5. 头 -----------------------------------------------------------
    head = ebox(100, head_cy, HEAD_R, HEAD_R)
    d.ellipse(head, fill=C_BODY)

    hp = quad((84, head_cy - 20), (100, head_cy - 27), (116, head_cy - 20))
    hp += quad((116, head_cy - 20), (111, head_cy - 10), (100, head_cy - 10))[1:]
    hp += quad((100, head_cy - 10), (89, head_cy - 10), (84, head_cy - 20))[1:]
    d.polygon([px(*p) for p in hp], fill=_blend(C_BODY, C_PATCH, 0.30))

    # 眼睛（open：两个竖椭圆 + 一个白点）
    eye_cy = head_cy - 2
    for ex in (89.0, 111.0):
        box = ebox(ex, eye_cy, 3.6, 4.2)
        d.ellipse(box, fill=C_EYE)
    d.ellipse(ebox(90.2, eye_cy - 1.6, 1.2, 1.2), fill=(255, 255, 255, 230))

    # 鼻子
    d.polygon([px(100, head_cy + 7), px(95.8, head_cy + 3.6), px(104.2, head_cy + 3.6)],
              fill=C_NOSE)

    # 嘴
    stroke_polyline(d, [(100, head_cy + 7), (100, head_cy + 10.4)], C_LINE, lw_thin)
    stroke_polyline(d, quad((100, head_cy + 10.4), (95.4, head_cy + 14), (92, head_cy + 10.4)),
                    C_LINE, lw_thin)
    stroke_polyline(d, quad((100, head_cy + 10.4), (104.6, head_cy + 14), (108, head_cy + 10.4)),
                    C_LINE, lw_thin)

    # 胡须（opacity 0.55）
    hair = _blend(C_LINE, (255, 255, 255), 0.45)
    for a, b in (((76, head_cy + 4), (61, head_cy + 1)),
                 ((76, head_cy + 8), (61, head_cy + 10)),
                 ((124, head_cy + 4), (139, head_cy + 1)),
                 ((124, head_cy + 8), (139, head_cy + 10))):
        stroke_polyline(d, [a, b], hair, lw_hair)

    # 头轮廓最后描，压住耳朵根
    d.ellipse(head, outline=C_LINE, width=int(round(lw)))

    return img


def _blend(fg, bg, alpha):
    return tuple(int(round(fg[i] * alpha + bg[i] * (1 - alpha))) for i in range(3))


# ---------------------------------------------------------------- 出帧

def build_frames(quiet=False):
    os.makedirs(OUT_FRAMES, exist_ok=True)
    paths = []
    for i in range(N_FRAMES):
        phase = i / float(N_FRAMES)
        big = draw_cat(phase)
        small = big.resize((BW, BH), Image.LANCZOS)
        p = os.path.join(OUT_FRAMES, "f%02d.png" % i)
        small.save(p)
        paths.append(p)
        if not quiet:
            print("  帧 %02d  位图 %dx%d  -> %s" % (i, BW, BH, os.path.basename(p)))
    return paths


def build_sheet():
    paths = build_frames(quiet=True)
    cols, cw, ch = 5, BW, BH
    rows = (len(paths) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cw, rows * ch), (250, 246, 240, 255))
    for k, p in enumerate(paths):
        sheet.paste(Image.open(p), ((k % cols) * cw, (k // cols) * ch), Image.open(p))
    out = os.path.join(ROOT, "Tools", "out", "cat_frames_sheet.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sheet.save(out)
    print("  拼图 -> %s" % out)
    return out


# ---------------------------------------------------------------- 造字体

DIGITS = [chr(ord("0") + i) for i in range(10)]
GLYPH_NAMES = {c: n for c, n in zip(DIGITS, [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"])}
EMPTY_CHARS = {":": "colon", ".": "period"}      # 给个空字形，免得 fallback 到系统字体


# 位图要覆盖的字号范围。组件里的猫大约 44~90pt，所以在这一段铺密一点。
# ★ 必须多档 —— 只给一个 strike 的话，别的字号下要么去缩放那一张（糊），
#   要么某些实现干脆判定「这个字号没有可用字形」直接不画（实测 FreeType 就是这样：
#   只给 256 一档时，44/80/224px 全部报 invalid pixel size）。
#   代码侧还会把字号钉在这些值上（见 StillWidget.swift 的 CAT_PT），双保险。
STRIKES = (40, 48, 56, 64, 72, 88, 112, 160, 224)


def _png_bytes(img):
    from io import BytesIO
    buf = BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def build_font():
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib import newTable
    from fontTools.ttLib.tables.sbixGlyph import Glyph as SbixGlyph
    from fontTools.ttLib.tables.sbixStrike import Strike

    units = 1000
    advance = units                        # 位图宽 = 1 em
    glyph_h = int(round(units * BH / float(BW)))   # 字形高 = 1 em * 224/256

    order = [".notdef"] + [GLYPH_NAMES[c] for c in DIGITS] + list(EMPTY_CHARS.values())

    # ★ 字形必须有**真实轮廓**（哪怕永远不画），否则字体被判定为「不可缩放」：
    #   FreeType 会直接报 invalid pixel size，系统也可能只在 ppem 那一刻才认它。
    #   这里给的是一个和位图等大的矩形。
    #   `sbix.flags` 的 bit1 = 0 表示「只画位图、不画轮廓」，所以这个框不会露出来。
    box = TTGlyphPen(None)
    box.moveTo((0, 0))
    box.lineTo((advance, 0))
    box.lineTo((advance, glyph_h))
    box.lineTo((0, glyph_h))
    box.closePath()
    box_glyph = box.glyph()

    fb = FontBuilder(units, isTTF=True)
    fb.setupGlyphOrder(order)

    cmap = {}
    for c in DIGITS:
        cmap[ord(c)] = GLYPH_NAMES[c]
    for c, n in EMPTY_CHARS.items():
        cmap[ord(c)] = n
    fb.setupCharacterMap(cmap)

    fb.setupGlyf({n: box_glyph for n in order})
    fb.setupHorizontalMetrics({n: (advance, 0) for n in order})
    fb.setupHorizontalHeader(ascent=glyph_h, descent=0)
    fb.setupNameTable({
        "familyName": "StillFrames",
        "styleName": "Regular",
        "fullName": "StillFrames Regular",
        "psName": "StillFrames-Regular",
        "version": "1.0",
    })
    fb.setupOS2(sTypoAscender=glyph_h, sTypoDescender=0,
                usWinAscent=glyph_h, usWinDescent=0)
    fb.setupPost()
    font = fb.font

    # ---- sbix：每个 strike 一套 10 张 PNG ----
    sbix = newTable("sbix")
    sbix.version = 1
    sbix.flags = 1          # bit0 必须为 1；bit1=0 → 只画位图

    # 先把 10 张超采样大图算出来，三个 strike 共用（否则要重画 30 次）
    bigs = [draw_cat(i / float(N_FRAMES)) for i in range(N_FRAMES)]

    for wpx in STRIKES:
        hpx = int(round(wpx * BH / float(BW)))
        st = Strike(ppem=wpx, resolution=72)
        for i, c in enumerate(DIGITS):
            bmp = bigs[i].resize((wpx, hpx), Image.LANCZOS)
            st.glyphs[GLYPH_NAMES[c]] = SbixGlyph(
                glyphName=GLYPH_NAMES[c],
                graphicType="png ",
                originOffsetX=0,
                originOffsetY=0,     # 位图左下角贴基线
                imageData=_png_bytes(bmp),
            )
        sbix.strikes[wpx] = st
        print("  strike %dpx (%dx%d)" % (wpx, wpx, hpx))

    font["sbix"] = sbix

    os.makedirs(os.path.dirname(OUT_FONT), exist_ok=True)
    fb.save(OUT_FONT)
    print("  字体 -> %s (%.1f KB)" % (OUT_FONT, os.path.getsize(OUT_FONT) / 1024.0))
    return OUT_FONT


# ---------------------------------------------------------------- 自检

def verify():
    """把造好的字体重新读一遍，确认每个 strike 的 10 个字形都在、PNG 能解出来。"""
    from fontTools.ttLib import TTFont
    from io import BytesIO

    f = TTFont(OUT_FONT)
    sbix = f["sbix"]
    all_ok = True
    for ppem, strike in sorted(sbix.strikes.items()):
        want = (ppem, int(round(ppem * BH / float(BW))))
        ok = 0
        for c in DIGITS:
            name = GLYPH_NAMES[c]
            g = strike.glyphs.get(name)
            if g is None or not g.imageData:
                print("   ✗ strike %d: %s 缺位图" % (ppem, name))
                continue
            im = Image.open(BytesIO(g.imageData))
            if im.size != want:
                print("   ✗ strike %d: %s 尺寸 %s != %s" % (ppem, name, im.size, want))
                continue
            ok += 1
        print("  strike %dpx：%d/10 字形带可解码位图" % (ppem, ok))
        all_ok = all_ok and ok == 10
    return all_ok


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    if cmd == "frames":
        build_frames()
    elif cmd == "sheet":
        build_sheet()
    else:
        print("[1/3] 出帧")
        build_frames()
        print("[2/3] 造字体")
        build_font()
        print("[3/3] 自检")
        verify()
