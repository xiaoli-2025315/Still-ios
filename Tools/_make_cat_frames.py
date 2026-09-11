# -*- coding: utf-8 -*-
"""
把 App 里那只毛毡猫（CatView.swift / CatPose.sit）按原封不动的矢量参数重画一遍，
输出一组「甩尾」逐帧图。

为什么不用 App 里的渲染：Windows 上没有 Swift。所以这里把 CatView.swift 的
坐标、配色、层级、线宽逐条抄过来 —— 坐标一律用逻辑坐标（200×175），
最后统一乘 S 缩放，跟 Swift 端一样。

产物：
  out/catframes/frame_00..09.png   透明底逐帧（喂给字体 / 组件）
  out/catframes/sheet.png          一张总览（肉眼看）
  out/catframes/preview.gif        暖米底循环动图（看效果）
"""

import math
import os
from PIL import Image, ImageDraw

# ---------------------------------------------------------------- 基本设置

W_LOG, H_LOG = 200.0, 175.0      # CatView.swift 的 SVG viewBox
OUT_W = 600                      # 最终单帧宽度（= 3x 逻辑）
SS = 4                           # 超采样倍数，缩回来当抗锯齿
S = (OUT_W / W_LOG) * SS         # 绘制时每逻辑单位多少像素
CW, CH = int(W_LOG * S), int(H_LOG * S)

HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.join(HERE, "out", "catframes")

FRAMES = 10                      # 一秒一帧 → 10 秒一轮
SWING_DEG = 22.0                 # 尾巴左右摆动的幅度（度）

# ---------------------------------------------------------------- 配色（CatColor）

C = {
    "body":     (0xE3, 0xD3, 0xC3),
    "bodyDark": (0xD3, 0xBF, 0xA9),
    "patch":    (0xC9, 0x7B, 0x4E),
    "ear":      (0xE8, 0xB4, 0xA0),
    "line":     (0x6B, 0x5D, 0x50),
    "nose":     (0xC9, 0x7B, 0x4E),
    "eye":      (0x4A, 0x3F, 0x35),
    "tongue":   (0xE8, 0xA0, 0xA0),
}
BG = (0xFA, 0xF6, 0xF0)          # Cfg.Palette.bg 暖米


def blend(fg, bg, a):
    """把 fg 以 alpha=a 叠在 bg 上，返回不透明色。斑块整个压在身体里，可以这样直接算。"""
    return tuple(int(round(bg[i] * (1 - a) + fg[i] * a)) for i in range(3))


def rgba(c, a=255):
    return (c[0], c[1], c[2], a)


# ---------------------------------------------------------------- 几何工具

def P(x, y):
    """逻辑坐标 → 画布坐标"""
    return (x * S, y * S)


def cubic(p0, p1, p2, p3, n=72):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((
            u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
        ))
    return out


def quad(p0, p1, p2, n=44):
    out = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        out.append((
            u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
            u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1],
        ))
    return out


def rot(pt, origin, deg):
    a = math.radians(deg)
    dx, dy = pt[0] - origin[0], pt[1] - origin[1]
    return (origin[0] + dx * math.cos(a) - dy * math.sin(a),
            origin[1] + dx * math.sin(a) + dy * math.cos(a))


def path_from(segments):
    """segments: ('m', p) / ('l', p) / ('c', p1,p2,p3) / ('q', p1,p2)，坐标是画布坐标"""
    pts = []
    cur = None
    for seg in segments:
        if seg[0] == 'm':
            cur = seg[1]
            pts.append(cur)
        elif seg[0] == 'l':
            cur = seg[1]
            pts.append(cur)
        elif seg[0] == 'c':
            pts += cubic(cur, seg[1], seg[2], seg[3])[1:]
            cur = seg[3]
        elif seg[0] == 'q':
            pts += quad(cur, seg[1], seg[2])[1:]
            cur = seg[2]
    return pts


def fill(d, pts, color, alpha=255):
    d.polygon(pts, fill=rgba(color, alpha))


def stroke(d, pts, color, w_px, closed=False, alpha=255):
    """PIL 的 line 是沿路径居中描边，跟 SVG stroke 一致；joint='curve' 给圆角拐弯。"""
    seq = list(pts) + ([pts[0]] if closed and len(pts) > 1 else [])
    d.line(seq, fill=rgba(color, alpha), width=max(1, int(round(w_px))),
           joint="curve")
    if not closed and len(pts) > 1:
        r = w_px / 2.0
        for p in (pts[0], pts[-1]):          # 圆头
            d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=rgba(color, alpha))


# ---------------------------------------------------------------- 姿势参数（CatPose.sit）

CX = 100.0
RY = 34.0
HEAD_CY = 58.0
HEAD_R = 30.0
PAW = 142.0
EAR_DEG = 0.0

LW = 1.7          # 主描边线宽（逻辑单位）
LW_MOUTH = 1.5
LW_WHISKER = 1.2

TAIL_CURL = [(146, 116), (176, 110), (180, 84), (161, 75), (151, 70), (142, 77), (147, 88)]


# ---------------------------------------------------------------- 各层

def draw_tail(d, deg):
    base = TAIL_CURL[0]
    p = [rot(pt, base, deg) for pt in TAIL_CURL]
    pts = path_from([('m', P(*p[0])),
                     ('c', P(*p[1]), P(*p[2]), P(*p[3])),
                     ('c', P(*p[4]), P(*p[5]), P(*p[6]))])
    fill(d, pts, C["bodyDark"])
    stroke(d, pts, C["line"], LW * S)


def draw_body(d):
    bbox = [P(CX - 50, 112 - RY), P(CX + 50, 112 + RY)]
    d.ellipse([bbox[0][0], bbox[0][1], bbox[1][0], bbox[1][1]], fill=rgba(C["body"]))

    y = 112 - RY * 0.42
    patch = path_from([
        ('m', P(CX - 34, y)),
        ('q', P(CX, y - 13), P(CX + 34, y)),
        ('q', P(CX + 26, y + 17), P(CX, y + 17)),
        ('q', P(CX - 26, y + 17), P(CX - 34, y)),
        ('l', P(CX - 34, y)),
    ])
    fill(d, patch, blend(C["patch"], C["body"], 0.28))

    d.ellipse([bbox[0][0], bbox[0][1], bbox[1][0], bbox[1][1]],
              outline=rgba(C["line"]), width=int(round(LW * S)))


def draw_paws(d):
    px, py = 11.0, 7.0
    lx, rx = 86.0, 114.0
    e = lambda cxx: [P(cxx - px, PAW - py), P(cxx + px, PAW + py)]

    d.ellipse([e(lx)[0][0], e(lx)[0][1], e(lx)[1][0], e(lx)[1][1]], fill=rgba(C["bodyDark"]))
    d.ellipse([e(rx)[0][0], e(rx)[0][1], e(rx)[1][0], e(rx)[1][1]], fill=rgba(C["body"]))
    for cxx in (lx, rx):
        d.ellipse([e(cxx)[0][0], e(cxx)[0][1], e(cxx)[1][0], e(cxx)[1][1]],
                  outline=rgba(C["line"]), width=int(round(LW * S)))


def draw_ears(d):
    cy = HEAD_CY
    tri = lambda a, b, c: [P(*a), P(*b), P(*c)]
    lo = tri((CX - 24, cy - 18), (CX - 30, cy - 44), (CX - 6, cy - 28))
    ro = tri((CX + 24, cy - 18), (CX + 30, cy - 44), (CX + 6, cy - 28))
    li = tri((CX - 23, cy - 21), (CX - 26, cy - 37), (CX - 12, cy - 27))
    ri = tri((CX + 23, cy - 21), (CX + 26, cy - 37), (CX + 12, cy - 27))

    o = (CX, cy)
    lo = [P(*rot((pt[0] / S, pt[1] / S), o, EAR_DEG)) for pt in lo]
    ro = [P(*rot((pt[0] / S, pt[1] / S), o, EAR_DEG)) for pt in ro]
    li = [P(*rot((pt[0] / S, pt[1] / S), o, EAR_DEG)) for pt in li]
    ri = [P(*rot((pt[0] / S, pt[1] / S), o, EAR_DEG)) for pt in ri]

    fill(d, lo, C["body"]); fill(d, ro, C["body"])
    fill(d, li, C["ear"]);  fill(d, ri, C["ear"])
    stroke(d, lo, C["line"], LW * S, closed=True)
    stroke(d, ro, C["line"], LW * S, closed=True)


def draw_head(d):
    cy = HEAD_CY
    bbox = [P(CX - HEAD_R, cy - HEAD_R), P(CX + HEAD_R, cy + HEAD_R)]
    d.ellipse([bbox[0][0], bbox[0][1], bbox[1][0], bbox[1][1]], fill=rgba(C["body"]))

    patch = path_from([
        ('m', P(CX - 16, cy - 20)),
        ('q', P(CX, cy - 27), P(CX + 16, cy - 20)),
        ('q', P(CX + 11, cy - 10), P(CX, cy - 10)),
        ('q', P(CX - 11, cy - 10), P(CX - 16, cy - 20)),
        ('l', P(CX - 16, cy - 20)),
    ])
    fill(d, patch, blend(C["patch"], C["body"], 0.30))

    # 眼睛（open）
    ey = cy - 2
    for cxx in (89.0, 111.0):
        e = [P(cxx - 3.6, ey - 4.2), P(cxx + 3.6, ey + 4.2)]
        d.ellipse([e[0][0], e[0][1], e[1][0], e[1][1]], fill=rgba(C["eye"]))
    hl = [P(90.2 - 1.2, ey - 1.6 - 1.2), P(90.2 + 1.2, ey - 1.6 + 1.2)]
    d.ellipse([hl[0][0], hl[0][1], hl[1][0], hl[1][1]], fill=(255, 255, 255, 230))

    # 鼻子
    fill(d, [P(CX, cy + 7), P(CX - 4.2, cy + 3.6), P(CX + 4.2, cy + 3.6)], C["nose"])

    # 嘴
    mouth = path_from([
        ('m', P(CX, cy + 7)), ('l', P(CX, cy + 10.4)),
        ('m', P(CX, cy + 10.4)), ('q', P(CX - 4.6, cy + 14), P(CX - 8, cy + 10.4)),
        ('m', P(CX, cy + 10.4)), ('q', P(CX + 4.6, cy + 14), P(CX + 8, cy + 10.4)),
    ])
    stroke(d, mouth, C["line"], LW_MOUTH * S)

    # 胡须
    whisk = []
    for (a, b) in [((CX - 24, cy + 4), (CX - 39, cy + 1)),
                   ((CX - 24, cy + 8), (CX - 39, cy + 10)),
                   ((CX + 24, cy + 4), (CX + 39, cy + 1)),
                   ((CX + 24, cy + 8), (CX + 39, cy + 10))]:
        stroke(d, [P(*a), P(*b)], C["line"], LW_WHISKER * S, alpha=140)

    # 头轮廓最后压上
    d.ellipse([bbox[0][0], bbox[0][1], bbox[1][0], bbox[1][1]],
              outline=rgba(C["line"]), width=int(round(LW * S)))


# ---------------------------------------------------------------- 出帧

def render(i):
    img = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")
    deg = SWING_DEG * math.sin(2 * math.pi * i / FRAMES)
    draw_tail(d, deg)      # ZStack 顺序：尾 → 身 → 爪 → 耳 → 头
    draw_body(d)
    draw_paws(d)
    draw_ears(d)
    draw_head(d)
    return img.resize((OUT_W, int(OUT_W * H_LOG / W_LOG)), Image.LANCZOS)


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    frames = []
    for i in range(FRAMES):
        im = render(i)
        im.save(os.path.join(OUTDIR, "frame_%02d.png" % i))
        frames.append(im)
    print("frames ->", OUTDIR, OUT_W, frames[0].size)

    # 总览
    cols, pad = 5, 8
    fw, fh = frames[0].size
    sw, sh = cols * (fw // 2 + pad) + pad, 2 * (fh // 2 + pad) + pad
    sheet = Image.new("RGB", (sw, sh), BG)
    for i, im in enumerate(frames):
        t = im.resize((fw // 2, fh // 2), Image.LANCZOS)
        x = pad + (i % cols) * (fw // 2 + pad)
        y = pad + (i // cols) * (fh // 2 + pad)
        sheet.paste(t, (x, y), t)
    sheet.save(os.path.join(OUTDIR, "sheet.png"))
    print("sheet ->", sheet.size)

    # 循环动图（暖米底，跟组件里的观感一致）
    gif = []
    for im in frames:
        bg = Image.new("RGB", im.size, BG)
        bg.paste(im, (0, 0), im)
        gif.append(bg.resize((OUT_W // 3, im.height // 3), Image.LANCZOS))
    gif[0].save(os.path.join(OUTDIR, "preview.gif"),
                save_all=True, append_images=gif[1:], duration=1000, loop=0, optimize=True)
    print("gif ->", gif[0].size)


if __name__ == "__main__":
    main()
