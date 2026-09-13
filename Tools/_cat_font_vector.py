#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""v27 帧动画：把 v26 的矢量猫变成「帧字体」。

原理（与 skill still-widget-animation 同源，但全矢量）：
  组件里唯一能每秒自己动、不花刷新额度的东西是 Text(timerInterval:)。
  把动画的每一帧画成自定义字体的一个字形（'0'..'9' = 10 帧，每秒翻一帧）。
  v21~v25 实证位图在组件进程全灭，所以这里**不用 sbix 位图**，
  每个字形 = 纯矢量轮廓（glyf），跟 v20~v26 一直能显示的爪印/矢量猫同一层。

多色怎么解决：一个轮廓字形只有一种颜色 → 按颜色分 5 层，每层一套字体，
Swift 侧用 ZStack 把 5 层 Text 叠在一起（同一个计时器，逐层对齐）。
半透明的线条（胡须 35%、脚趾缝 45%）按已知底色**预混成实色**，不靠 alpha。

产物：
  Sources/Widget/CatFrameFonts.swift   —— 5 套字体的 base64，直接编进二进制
                                          （扩展包里不出现任何 .ttf 文件）
  dist/cat_anim_sheet.png              —— 从生成的字体渲出来的 10 帧预览（自检用）

几何来源：Sources/Widget/StillWidget.swift 的 VectorCat（v26），逐条照抄。
改动只有两处：尾巴按正弦摆动（根部少动、末端多动），第 5 帧眨眼。
"""

import base64
import math
import os

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))

# ---------------------------------------------------------------
# 坐标系
#   设计坐标：v26 的 172x230（y 向下）。因为尾巴会摆出 x>172，
#   画布加宽到 200，所有形状整体左移 13.5 居中。
#   字体坐标：y 向上、原点在基线。unitsPerEm=1000，scale=5：
#     fontX = (x - 13.5) * 5
#     fontY = (230 - y) * 5      → 字形高 1150
# ---------------------------------------------------------------
SCALE = 5.0
XOFF = 13.5
GLYPH_H = 1150          # 230 * 5
ADVANCE = 1000          # 画布宽 200 * 5 = 1 em
N_FRAMES = 10

def fx(x):
    return (x - XOFF) * SCALE

def fy(y):
    return (230.0 - y) * SCALE

# v26 VectorCat 的配色（16 进制来自同样的 Color(red:green:blue:)）
FUR = (201, 123, 78)
DARK = (153, 89, 54)
INK = (61, 43, 31)
CREAM = (242, 222, 194)
# 胡须 = ink 35% 叠在 fur 上（预混实色）；脚趾缝用同一档，视觉差别可忽略
SOFT = tuple(round(INK[i] * 0.35 + FUR[i] * 0.65) for i in range(3))

LAYERS = [("Fur", FUR), ("Cream", CREAM), ("Dark", DARK),
          ("Ink", INK), ("Soft", SOFT)]

# ---------------------------------------------------------------
# 形状工具（设计坐标）
# ---------------------------------------------------------------

def ellipse_poly(x, y, w, h, n=40):
    """矩形 (x,y,w,h) 内的椭圆，返回多边形点列。"""
    cx, cy, rx, ry = x + w / 2, y + h / 2, w / 2, h / 2
    return [(cx + rx * math.cos(2 * math.pi * i / n),
             cy + ry * math.sin(2 * math.pi * i / n)) for i in range(n)]


def circle_poly(cx, cy, r, n=16):
    return [(cx + r * math.cos(2 * math.pi * i / n),
             cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def quad_pts(p0, c, p1, n=24):
    """二次贝塞尔采样成折线。"""
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t ** 2 * p1[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t ** 2 * p1[1])
            for t in (i / n for i in range(n + 1))]


def stroke_polys(pts, w):
    """把有宽度的描边转成实心轮廓：中线两侧偏移 w/2 + 两端圆帽。
    返回多边形列表（全部同色层内重叠没关系，nonzero 填充并成一体）。"""
    left, right = [], []
    n = len(pts)
    for i in range(n):
        if i == 0:
            dx, dy = pts[1][0] - pts[0][0], pts[1][1] - pts[0][1]
        elif i == n - 1:
            dx, dy = pts[-1][0] - pts[-2][0], pts[-1][1] - pts[-2][1]
        else:
            dx, dy = pts[i + 1][0] - pts[i - 1][0], pts[i + 1][1] - pts[i - 1][1]
        L = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / L, dx / L
        half = w / 2
        left.append((pts[i][0] + nx * half, pts[i][1] + ny * half))
        right.append((pts[i][0] - nx * half, pts[i][1] - ny * half))
    out = [left + right[::-1],
           circle_poly(pts[0][0], pts[0][1], w / 2),
           circle_poly(pts[-1][0], pts[-1][1], w / 2)]
    return out


def seg(x0, y0, x1, y1, w):
    return stroke_polys([(x0, y0), (x1, y1)], w)

# ---------------------------------------------------------------
# 每帧的形状（返回 {层名: [多边形, ...]}，设计坐标）
#   动画 = 尾巴正弦摆动（根部少动、末端多动）+ 第 5 帧眨眼
# ---------------------------------------------------------------

def frame_shapes(f):
    phase = 2 * math.pi * f / N_FRAMES
    sway = math.sin(phase)

    # 尾巴：v26 的 (126,212)→ctrl(174,198)→end(156,146)，根部钉死
    c = (174 + sway * 10, 198)
    e = (156 + sway * 16, 146)
    tail = quad_pts((126, 212), c, e)
    tail_tip = seg(e[0], e[1] + 16, e[0], e[1], 15)

    fur = []
    fur += stroke_polys(tail, 15)                    # 尾巴（先画，根被身体压住）
    fur.append(ellipse_poly(38, 106, 96, 118))       # 身体
    fur.append([(50, 50), (59, 6), (84, 32)])        # 左耳
    fur.append([(122, 50), (113, 6), (88, 32)])      # 右耳
    fur.append(ellipse_poly(42, 26, 88, 86))         # 头
    fur.append(ellipse_poly(54, 206, 30, 19))        # 左前爪
    fur.append(ellipse_poly(88, 206, 30, 19))        # 右前爪

    cream = [ellipse_poly(64, 128, 44, 66)]          # 胸脯

    dark = []
    dark += tail_tip                                  # 尾巴尖（深色一截）
    # 耳内层：比 v26 略收小 —— 分层绘制里深色层在头之后，收到不压头顶线为止
    dark.append([(59, 34), (64, 15), (75, 26)])
    dark.append([(113, 34), (108, 15), (97, 26)])
    for dx in (-15, 0, 15):                          # 头顶三道纹
        dark += stroke_polys(quad_pts((86 + dx, 32), (86 + dx, 42),
                                      (86 + dx * 1.5, 48)), 5)
    for x0, dr in ((40, 1), (132, -1)):              # 体侧各两道纹
        for i in range(2):
            y = 148 + i * 22
            dark += stroke_polys(quad_pts((x0, y), (x0 + 2 * dr, y + 8),
                                          (x0 + 14 * dr, y + 8)), 5)
    dark.append([(80, 79), (92, 79), (86, 86)])      # 鼻子

    ink = []
    if f == 5:                                       # 眨眼：眼睛闭成一横线
        ink += seg(61, 65.5, 72, 65.5, 3.5)
        ink += seg(100, 65.5, 111, 65.5, 3.5)
    else:
        ink.append(ellipse_poly(61, 60, 11, 11))
        ink.append(ellipse_poly(100, 60, 11, 11))
    ink += stroke_polys(quad_pts((86, 86), (81, 91), (78, 92)), 2)   # 嘴
    ink += stroke_polys(quad_pts((86, 86), (91, 91), (94, 92)), 2)

    soft = []
    for x0, y0, x1, y1 in ((58, 82, 30, 78), (58, 89, 32, 96),
                           (114, 82, 142, 78), (114, 89, 140, 96)):
        soft += seg(x0, y0, x1, y1, 1.6)             # 胡须
    for px in (62, 70, 96, 104):
        soft += seg(px, 212, px, 222, 1.6)           # 脚趾缝

    return {"Fur": fur, "Cream": cream, "Dark": dark,
            "Ink": ink, "Soft": soft}

# ---------------------------------------------------------------
# 设计坐标 → 字体轮廓
# ---------------------------------------------------------------

def _signed_area(poly):
    s = 0.0
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        s += x0 * y1 - x1 * y0
    return s / 2


def to_font_polys(polys):
    """转字体坐标 + 统一绕向（nonzero 填充下同向重叠 = 并集，反向会出洞）。"""
    out = []
    for poly in polys:
        p = [(fx(x), fy(y)) for x, y in poly]
        if _signed_area(p) < 0:
            p.reverse()
        out.append(p)
    return out

# ---------------------------------------------------------------
# 造字体（每层一套，纯 glyf 轮廓，10 个数字字形 = 10 帧）
# ---------------------------------------------------------------

def build_font(name, frames_polys, path):
    order = [".notdef"] + ["frame%d" % i for i in range(N_FRAMES)] + ["colon", "period"]
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    cmap = {ord(str(i)): "frame%d" % i for i in range(N_FRAMES)}
    cmap[ord(":")] = "colon"
    cmap[ord(".")] = "period"
    fb.setupCharacterMap(cmap)

    glyphs = {}
    pen = TTGlyphPen(None)                            # .notdef：实心方块占位
    pen.moveTo((0, 0)); pen.lineTo((ADVANCE, 0))
    pen.lineTo((ADVANCE, GLYPH_H)); pen.lineTo((0, GLYPH_H))
    pen.closePath()
    glyphs[".notdef"] = pen.glyph()
    for i in range(N_FRAMES):
        pen = TTGlyphPen(None)
        for poly in frames_polys[i]:
            pen.moveTo(poly[0])
            for pt_ in poly[1:]:
                pen.lineTo(pt_)
            pen.closePath()
        glyphs["frame%d" % i] = pen.glyph()
    for extra in ("colon", "period"):                 # 冒号/句点：空字形占位
        glyphs[extra] = TTGlyphPen(None).glyph()
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({n: (ADVANCE, 0) for n in order})
    fb.setupHorizontalHeader(ascent=GLYPH_H, descent=0)
    fb.setupOS2(sTypoAscender=GLYPH_H, sTypoDescender=0,
                usWinAscent=GLYPH_H, usWinDescent=0)
    fb.setupNameTable({"familyName": name, "styleName": "Regular",
                       "fullName": name, "psName": name,
                       "uniqueFontIdentifier": name + ";1.0",
                       "version": "Version 1.0"})
    fb.setupPost()
    fb.save(path)

# ---------------------------------------------------------------
# 自检：从生成的字体渲出 10 帧（PIL / FreeType，和 CoreText 同源数据）
# ---------------------------------------------------------------

def render_sheet(font_dir, out_path):
    from PIL import Image, ImageDraw, ImageFont
    pt = 80
    cell_w, cell_h = 92, 100
    sheet = Image.new("RGB", (cell_w * N_FRAMES, cell_h), (250, 246, 240))
    for f in range(N_FRAMES):
        cell = Image.new("RGB", (cell_w, cell_h), (250, 246, 240))
        for lname, rgb in LAYERS:
            font = ImageFont.truetype(
                os.path.join(font_dir, "StillCat%s.ttf" % lname), pt)
            mask = Image.new("L", (cell_w, cell_h), 0)
            ImageDraw.Draw(mask).text((2, 2), str(f), font=font, fill=255)
            solid = Image.new("RGB", (cell_w, cell_h), rgb)
            cell.paste(solid, (0, 0), mask)
        sheet.paste(cell, (f * cell_w, 0))
    sheet.save(out_path)
    return out_path

# ---------------------------------------------------------------
# 生成 Swift 数据文件
# ---------------------------------------------------------------

SWIFT_HEADER = """\
// MARK: - 内嵌帧字体（v27：猫的帧动画，纯矢量轮廓）
//
// 原理：组件里唯一能每秒自更新、不花刷新额度的是 Text(timerInterval:)。
// 把动画的每一帧画成字体的一个字形（'0'..'9' = 10 帧），计时器最后一位数字翻页。
//
// ★ 全部是矢量轮廓（glyf），没有任何位图 —— v21~v25 实证位图在组件进程全灭，
//   而矢量从 v20 起每一次都显示成功。多色 = 按颜色分 5 层字体，Swift 侧 ZStack 叠放。
//
// ★ 本文件由 Tools/_cat_font_vector.py 生成，不要手改 —— 改帧/改色去改那个脚本重跑。
// ★ 字体数据直接编进二进制：扩展包里不出现任何 .ttf 文件，
//   不碰「系统启动扩展时解析字体」那条路（v10~v19 的教训）。

enum CatFrameFonts {
    struct FontDef {
        let name: String   // 字体家族名（.custom 用）
        let b64: String    // ttf 的 base64
    }

    static let all: [FontDef] = [
"""


def main():
    font_dir = os.path.join(TMP_DIR := os.path.join(ROOT, "Tools", "_frames_tmp"), "")
    os.makedirs(font_dir, exist_ok=True)

    per_layer = {}
    for lname, _rgb in LAYERS:
        frames = []
        for f in range(N_FRAMES):
            shapes = frame_shapes(f)[lname]
            frames.append(to_font_polys(shapes))
        per_layer[lname] = frames
        build_font("StillCat" + lname, frames,
                   os.path.join(font_dir, "StillCat%s.ttf" % lname))
        print("built StillCat%s.ttf" % lname)

    # Swift 数据文件
    defs = []
    for lname, _rgb in LAYERS:
        b = open(os.path.join(font_dir, "StillCat%s.ttf" % lname), "rb").read()
        b64 = base64.b64encode(b).decode()
        lines = [b64[i:i + 116] for i in range(0, len(b64), 116)]
        body = "\n".join('        "%s" + ' % l for l in lines).rstrip(" +")
        defs.append('        FontDef(name: "StillCat%s", b64:\n%s),' % (lname, body))
    swift = SWIFT_HEADER + "\n".join(defs).rstrip(",") + "\n    ]\n}\n"
    out_swift = os.path.join(ROOT, "Sources", "Widget", "CatFrameFonts.swift")
    with open(out_swift, "w", encoding="utf-8") as fh:
        fh.write(swift)
    total = sum(len(open(os.path.join(font_dir, "StillCat%s.ttf" % l), "rb").read())
                for l, _ in LAYERS)
    print("Swift:", out_swift, "  5 套字体共", total, "B")

    # 自检预览
    sheet = render_sheet(font_dir, os.path.join(ROOT, "dist", "cat_anim_sheet.png"))
    print("预览:", sheet)


if __name__ == "__main__":
    main()
