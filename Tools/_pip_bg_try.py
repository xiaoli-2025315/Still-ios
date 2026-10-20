#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
毛玻璃底图 · 三档对照
=====================
只在 Tools/out/pip 里出 try_*.png，不动 room_bg.png。
用法：python _pip_bg_try.py
"""
import os
import json
import random
import subprocess

import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageEnhance

ROOT = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(ROOT, 'out', 'pip')
TMP = os.path.join(ROOT, 'out', 'pip_tmp')
SRC = 'D:/素材/动作'
EXE = imageio_ffmpeg.get_ffmpeg_exe()

S = 720
CAT_H = 0.56
GROUND = 0.80
REF = '坐立张望'


# ---------------------------------------------------------------- 位点换算
def uni_params():
    data = json.load(open(os.path.join(TMP, 'placement.json'), encoding='utf-8'))
    rec = data[REF]
    W, H = rec['frame']
    bb = rec['bbox']
    sc = (S * CAT_H) / (bb[3] - bb[1])
    ox = S / 2 - (bb[0] + bb[2]) / 2 * sc
    oy = S * GROUND - bb[3] * sc
    return data, (sc, ox, oy)


def cat_frame(name, t, sc, ox, oy):
    """从源 mov 抽一帧（带透明），缩到方画布里的位置。"""
    png = os.path.join(OUT, '_c_%s.png' % name)
    subprocess.run([EXE, '-y', '-v', 'error', '-ss', str(t),
                    '-i', os.path.join(SRC, name, name + '-1.mov'),
                    '-frames:v', '1', png], capture_output=True)
    im = Image.open(png).convert('RGBA')
    W, H = im.size
    im = im.resize((int(W * sc), int(H * sc)), Image.LANCZOS)
    canvas = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    canvas.paste(im, (int(ox), int(oy)), im)
    return canvas


# ---------------------------------------------------------------- 底图
def vgrad(top, bot, extra=None):
    im = Image.new('RGB', (S, S), top)
    d = ImageDraw.Draw(im)
    for y in range(S):
        t = y / (S - 1.0)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (S, y)], fill=c)
    return im


def blotch(im, seed, palm):
    """隔着玻璃看到的一团模糊世界。"""
    rnd = random.Random(seed)
    layer = Image.new('RGB', (S, S), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    for _ in range(9):
        cx = rnd.uniform(-0.15, 1.15) * S
        cy = rnd.uniform(-0.05, 0.95) * S
        rx = rnd.uniform(0.12, 0.34) * S
        ry = rnd.uniform(0.10, 0.30) * S
        col = rnd.choice(palm)
        d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=col)
    layer = layer.filter(ImageFilter.GaussianBlur(96))
    m = Image.new('L', (S, S), 34)
    return Image.composite(Image.blend(im, layer, 0.30), im, m)


def streak(im, poly, alpha, blur):
    hi = Image.new('L', (S, S), 0)
    ImageDraw.Draw(hi).polygon(poly, fill=alpha)
    hi = hi.filter(ImageFilter.GaussianBlur(blur))
    return Image.composite(Image.new('RGB', (S, S), '#FFFFFF'), im, hi)


def ground_shadow(im):
    """猫脚下一点接触影 —— 没有它，猫像贴上去的。"""
    sh = Image.new('L', (S, S), 0)
    cy = S * GROUND + 6
    # 只做一层很宽的柔影：各段猫站的位置不一样，硬影一定对不上，
    # 宽影读起来像「地面上有一点暗」，永远不会错位。
    ImageDraw.Draw(sh).ellipse([S * 0.47 - S * 0.400, cy - S * 0.050,
                                S * 0.47 + S * 0.400, cy + S * 0.050], fill=30)
    sh = sh.filter(ImageFilter.GaussianBlur(44))
    return Image.composite(Image.new('RGB', (S, S), '#8A93A3'), im, sh)


def grain(im, amp=4):
    n = Image.effect_noise((S, S), amp).convert('L')
    n = n.point(lambda v: 128 + int((v - 128) * 0.6)).convert('RGB')
    return ImageChops.add(im, n, 1.0, -128)


# ---------------------------------------------------------------- 三档
def bg_a():
    # 冷白雾面：最像 iPhone 上那块磨砂玻璃，也最不抢猫
    im = vgrad((0xFA, 0xFC, 0xFE), (0xE3, 0xE9, 0xF2))
    im = blotch(im, 11, [(0xDF, 0xE8, 0xF4), (0xE9, 0xEE, 0xF6), (0xDC, 0xE6, 0xF2)])
    im = streak(im, [(0, 0), (int(S * 0.42), 0), (int(S * 0.16), int(S * 0.52)), (0, int(S * 0.62))], 40, 60)
    im = streak(im, [(int(S * 0.34), 0), (int(S * 0.50), 0), (int(S * 0.26), int(S * 0.38)), (int(S * 0.20), int(S * 0.34))], 26, 34)
    im = ground_shadow(im)
    return grain(im, 4)


def bg_b():
    # 暖白雾面：跟 App 里那套暖白界面接得上
    im = vgrad((0xFC, 0xFB, 0xF9), (0xE9, 0xE6, 0xE1))
    im = blotch(im, 23, [(0xF0, 0xE9, 0xE0), (0xE6, 0xE4, 0xE2), (0xF2, 0xEE, 0xE8)])
    im = streak(im, [(0, 0), (int(S * 0.40), 0), (int(S * 0.14), int(S * 0.50)), (0, int(S * 0.60))], 42, 62)
    im = ground_shadow(im)
    return grain(im, 5)


def bg_c():
    # 明显玻璃：底更冷更深，反光更硬，一眼看出是块玻璃
    im = vgrad((0xF2, 0xF6, 0xFB), (0xD8, 0xE0, 0xEC))
    im = blotch(im, 37, [(0xCF, 0xDD, 0xEE), (0xDD, 0xE6, 0xF2), (0xC9, 0xD8, 0xEA)])
    im = streak(im, [(0, 0), (int(S * 0.46), 0), (int(S * 0.20), int(S * 0.60)), (0, int(S * 0.70))], 54, 54)
    im = streak(im, [(int(S * 0.30), 0), (int(S * 0.46), 0), (int(S * 0.24), int(S * 0.44)), (int(S * 0.16), int(S * 0.40))], 34, 26)
    # 边缘一圈亮线：玻璃的边
    rim = Image.new('L', (S, S), 0)
    ImageDraw.Draw(rim).rounded_rectangle([6, 6, S - 7, S - 7], radius=26, outline=150, width=5)
    rim = rim.filter(ImageFilter.GaussianBlur(9))
    im = Image.composite(Image.new('RGB', (S, S), '#FFFFFF'), im, rim)
    im = ground_shadow(im)
    return grain(im, 4)


def blob_layer(seed, items, blur):
    layer = Image.new('RGB', (S, S), (255, 255, 255))
    d = ImageDraw.Draw(layer)
    for (cx, cy, rx, ry, col) in items:
        d.ellipse([S * (cx - rx), S * (cy - ry), S * (cx + rx), S * (cy + ry)], fill=col)
    return layer.filter(ImageFilter.GaussianBlur(blur))


def bg_d():
    """冷调雾面玻璃：白底 + 隔着玻璃的一层柔光色块 + 一道斜光"""
    im = vgrad((0xFA, 0xFC, 0xFF), (0xE6, 0xEC, 0xF5))
    world = blob_layer(5, [
        (0.12, 0.14, 0.30, 0.26, (0xDD, 0xE7, 0xF6)),   # 左上冷
        (0.86, 0.22, 0.28, 0.30, (0xF3, 0xE7, 0xDF)),   # 右上暖
        (0.74, 0.86, 0.34, 0.22, (0xD9, 0xE2, 0xEF)),   # 右下
        (0.06, 0.72, 0.26, 0.24, (0xEE, 0xE4, 0xE2)),   # 左下
    ], 110)
    im = Image.blend(im, world, 0.55)
    # 透进来的一团亮光（磨砂玻璃后面那盏灯）
    lamp = blob_layer(7, [(0.24, 0.30, 0.13, 0.12, (0xFF, 0xFF, 0xFF)),
                          (0.30, 0.36, 0.07, 0.06, (0xFF, 0xFF, 0xFF))], 44)
    im = Image.blend(im, lamp, 0.34)
    # 斜光
    im = streak(im, [(0, 0), (int(S * 0.52), 0),
                     (int(S * 0.22), int(S * 0.66)), (0, int(S * 0.78))], 46, 52)
    im = streak(im, [(int(S * 0.44), 0), (int(S * 0.60), 0),
                     (int(S * 0.34), int(S * 0.30)), (int(S * 0.26), int(S * 0.26))], 30, 24)
    # 四角稍稍压一点，别再是一张白纸
    vig = Image.new('L', (S, S), 0)
    ImageDraw.Draw(vig).ellipse([int(-S * 0.12), int(-S * 0.12),
                                 int(S * 1.12), int(S * 1.12)], fill=255)
    vig = vig.point(lambda v: 120 + int(v * 0.40)).filter(ImageFilter.GaussianBlur(90))
    im = Image.composite(im, ImageEnhance.Brightness(im).enhance(0.90), vig)
    im = ground_shadow(im)
    return grain(im, 6)


def bg_e():
    """暖调雾面玻璃：跟 App 的暖白界面接得上"""
    im = vgrad((0xFE, 0xFD, 0xFB), (0xEC, 0xE8, 0xE3))
    world = blob_layer(9, [
        (0.14, 0.16, 0.32, 0.28, (0xF1, 0xE9, 0xDE)),
        (0.84, 0.26, 0.28, 0.30, (0xE7, 0xE9, 0xF0)),
        (0.72, 0.88, 0.34, 0.22, (0xE9, 0xE4, 0xDE)),
        (0.08, 0.74, 0.26, 0.24, (0xF4, 0xEB, 0xE2)),
    ], 110)
    im = Image.blend(im, world, 0.55)
    lamp = blob_layer(13, [(0.26, 0.28, 0.14, 0.13, (0xFF, 0xFF, 0xFF)),
                           (0.31, 0.35, 0.07, 0.06, (0xFF, 0xFF, 0xFF))], 46)
    im = Image.blend(im, lamp, 0.36)
    im = streak(im, [(0, 0), (int(S * 0.50), 0),
                     (int(S * 0.20), int(S * 0.64)), (0, int(S * 0.76))], 44, 54)
    vig = Image.new('L', (S, S), 0)
    ImageDraw.Draw(vig).ellipse([int(-S * 0.12), int(-S * 0.12),
                                 int(S * 1.12), int(S * 1.12)], fill=255)
    vig = vig.point(lambda v: 125 + int(v * 0.40)).filter(ImageFilter.GaussianBlur(90))
    im = Image.composite(im, ImageEnhance.Brightness(im).enhance(0.92), vig)
    im = ground_shadow(im)
    return grain(im, 6)


def bg_f():
    """定稿：隔着磨砂玻璃的一片柔光。四团淡色 + 一道斜光 + 细颗粒。"""
    world = Image.new('RGB', (S, S), (255, 255, 255))
    d = ImageDraw.Draw(world)
    for (cx, cy, rx, ry, c) in [
        (0.10, 0.12, 0.34, 0.30, (0xB9, 0xCE, 0xE8)),   # 左上冷蓝
        (0.88, 0.20, 0.30, 0.32, (0xE8, 0xD3, 0xC2)),   # 右上暖
        (0.78, 0.88, 0.36, 0.24, (0xC8, 0xD3, 0xE6)),   # 右下
        (0.08, 0.78, 0.28, 0.26, (0xDC, 0xD3, 0xE4)),   # 左下
    ]:
        d.ellipse([S * (cx - rx), S * (cy - ry), S * (cx + rx), S * (cy + ry)], fill=c)
    world = world.filter(ImageFilter.GaussianBlur(150))
    im = Image.blend(world, Image.new('RGB', (S, S), '#FFFFFF'), 0.42)
    im = streak(im, [(0, 0), (int(S * 0.50), 0),
                     (int(S * 0.20), int(S * 0.66)), (0, int(S * 0.78))], 52, 50)
    im = ground_shadow(im)
    return grain(im, 6)


def main():
    data, (sc, ox, oy) = uni_params()
    cats = [('坐立张望', 2.0), ('走动', 3.0)]
    frames = [(n, cat_frame(n, t, sc, ox, oy)) for n, t in cats]

    for tag, fn in [('A', bg_a), ('D', bg_d), ('F', bg_f)]:
        bg = fn()
        bg.save(os.path.join(OUT, 'bg_%s.png' % tag))
        shots = []
        for n, cf in frames:
            im = bg.copy()
            im.paste(cf, (0, 0), cf)
            p = os.path.join(OUT, 'shot_%s_%s.png' % (tag, n))
            im.save(p)
            shots.append(p)
        # 缩到画中画实际大小，看它到底糊不糊
        im = bg.copy()
        im.paste(frames[0][1], (0, 0), frames[0][1])
        im.resize((300, 300), Image.LANCZOS).save(os.path.join(OUT, 'small_%s.png' % tag))
        print('OK', tag)


if __name__ == '__main__':
    main()
