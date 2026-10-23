#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Still · 自带那只猫的「动作包」（让它也能被抓起来拖）
=====================================================
★ 为什么需要这个（2026-10-23，他的原话：「切一套透明帧打进包」）

  原来的自带猫是 **猫和房间合成在一整段 mp4 里**（_pip_compose.py 做的）。
  画面能看，但「猫」不是一张能移动的图 —— 想抓起来拖，做不到。

  装台子上的猫天生是分开的：房间底图 + 384×216 的透明帧（act.json + acts/<动作>/…webp）。
  这里就把自带那只也做成同一种包 ⇒ 两条渲染路并成一条，抓/拖/回中心全都成立。

★ 摆位跟 _pip_compose.py 的 `uniform_params` 是同一套，不是另起一套：
  · 各段是**同一机位、同一只猫**，所以整帧用**同一个**缩放和偏移（不按各自 bbox 对齐，
    那样换段时猫会跳一下）；
  · 基准段取「坐立张望」，猫高 = 画布高 × 0.72、脚线 = 画布高 × 0.90
    —— 这两个数就是台子 `act_align.py` 的目标值，装了台子上的猫才能一模一样大。

用法
  python _make_builtin_pack.py          → Resources/builtin_pack.zip
  python _make_builtin_pack.py --check  → 只出对照图，不打包
"""
import os
import io
import sys
import json
import glob
import zipfile
import subprocess

from PIL import Image
import imageio_ffmpeg

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = 'D:/素材/动作'
OUT = os.path.join(ROOT, 'out', 'builtin_pack')
DEST = os.path.join(ROOT, '..', 'Resources', 'builtin_pack.zip')
EXE = imageio_ffmpeg.get_ffmpeg_exe()

FW, FH = 384, 216        # 包里的帧尺寸（跟台子的包完全一致）
CAT_H = 0.72             # 猫高占帧高
GROUND = 0.90            # 脚线占帧高
FPS = 15                 # 帧率（跟小窗喂帧的频率一样，再高也看不出来）
REF = '坐立张望'          # 基准段：用它定「猫多大、站哪儿」

# 台子上的动作名 ← 本地素材目录名
#   ★ 名字必须是 `LiveFramePump.clipMap` 里那一套，否则换段时找不到会掉回 sit。
ACTS = [
    ('sit',      '坐着张望', '坐立张望',   'persist'),
    ('groom',    '舔毛',     '舔毛',       'persist'),
    ('sleep',    '睡着',     '持续睡觉',   'persist'),
    ('walk_r',   '走动',     '走动',       'persist'),
    ('struggle', '挣扎',     '持续挣扎',   'persist'),
    ('wake',     '睡醒',     '睡醒起身',   'event'),
    ('hunt1',    '扑着玩',   '捕猎1',      'event'),
    ('hunt2',    '再扑一次', '捕猎2',      'event'),
]


def probe_bbox(mov):
    """抽一帧（1/3 处，避开开头静止段）算猫的包围盒。跟 _pip_compose.probe 一个口径。"""
    err = subprocess.run([EXE, '-i', mov], capture_output=True, text=True,
                         errors='ignore').stderr
    dur = 0.0
    for ln in err.splitlines():
        if 'Duration:' in ln:
            t = ln.split('Duration:')[1].split(',')[0].strip()
            h, m, s = t.split(':')
            dur = float(h) * 3600 + float(m) * 60 + float(s)
            break

    tmp = os.path.join(OUT, '_probe.png')
    os.makedirs(OUT, exist_ok=True)
    subprocess.run([EXE, '-y', '-ss', '%.2f' % (dur / 3.0), '-i', mov,
                    '-frames:v', '1', tmp], capture_output=True)
    im = Image.open(tmp).convert('RGBA')
    W, H = im.size
    bb = im.split()[3].getbbox() or (0, 0, W, H)
    return dur, W, H, bb


def plan():
    """算「整帧统一映射」：源画布 → 384×216 的那一个缩放和偏移。"""
    mov = sorted(glob.glob(os.path.join(SRC, REF, '*.mov')))[0]
    dur, W, H, bb = probe_bbox(mov)
    bh = bb[3] - bb[1]
    cx = (bb[0] + bb[2]) / 2.0

    k = (FH * CAT_H) / bh                      # 源像素 → 帧像素
    fw, fh = int(round(W * k)), int(round(H * k))
    ox = int(round(FW / 2.0 - cx * k))
    oy = int(round(FH * GROUND - bb[3] * k))

    print('基准段 %s：%dx%d  dur=%.2fs  猫高=%dpx (%.1f%%)  中心x=%d' %
          (REF, W, H, dur, bh, bh * 100.0 / H, cx))
    print('统一映射：缩放 %.5f  整帧→%dx%d  粘贴于 (%d, %d)' % (k, fw, fh, ox, oy))
    if ox < 0 or oy < 0 or ox + fw > FW or oy + fh > FH:
        print('⚠ 整帧放不进 %dx%d —— 会被裁掉边（透明区，一般没事）' % (FW, FH))
    return k, fw, fh, ox, oy


def build(k, fw, fh, ox, oy, check_only=False):
    os.makedirs(OUT, exist_ok=True)
    man_acts = []
    total = 0

    for name, display, dname, cat in ACTS:
        movs = sorted(glob.glob(os.path.join(SRC, dname, '*.mov')))
        if not movs:
            print('✗ %s：%s 里没有 mov' % (name, dname))
            continue
        mov = movs[0]

        # ffmpeg 直接把每一帧做成 384×216 的透明画布：
        #   fps 抽帧 → 按统一缩放缩到 fw×fh → pad 到 384×216（左上角放在 ox,oy，其余透明）
        pad_x = max(0, ox)
        pad_y = max(0, oy)
        vf = ('fps=%d,scale=%d:%d:flags=lanczos,'
              'pad=%d:%d:%d:%d:color=0x00000000,format=rgba'
              % (FPS, fw, fh, FW, FH, pad_x, pad_y))
        cmd = [EXE, '-v', 'error', '-i', mov, '-vf', vf, '-f', 'rawvideo',
               '-pix_fmt', 'rgba', '-']
        proc = subprocess.run(cmd, capture_output=True)
        raw = proc.stdout
        one = FW * FH * 4
        n = len(raw) // one
        if n == 0:
            print('✗ %s：一帧都没解出来（%s）' % (name, proc.stderr[:200]))
            continue

        adir = os.path.join(OUT, 'acts', name)
        os.makedirs(adir, exist_ok=True)
        for i in range(n):
            im = Image.frombytes('RGBA', (FW, FH), raw[i * one:(i + 1) * one])
            im.save(os.path.join(adir, 'f_%s_%04d.webp' % (name, i)),
                    'WEBP', quality=72, method=4)
        total += n
        man_acts.append({
            'name': name, 'display': display, 'frames': n,
            'oneshot': 1 if cat == 'event' else 0,
            'category': cat, 'fps': FPS,
            'foot': round(FH * GROUND, 1),
        })
        print('  %-9s ← %-8s %3d 帧' % (name, dname, n))

    print('合计 %d 帧' % total)

    if check_only:
        # 拼一张对照图：每段取中间一帧，横着摆一排
        cols = [Image.open(os.path.join(OUT, 'acts', a['name'],
                                        'f_%s_%04d.webp' % (a['name'], a['frames'] // 2)))
                .convert('RGBA') for a in man_acts]
        sheet = Image.new('RGBA', (FW * len(cols), FH), (238, 242, 248, 255))
        for i, c in enumerate(cols):
            sheet.alpha_composite(c, (i * FW, 0))
        p = os.path.join(OUT, '_check.png')
        sheet.convert('RGB').save(p)
        print('→ 对照图 %s' % p)
        return

    man = {'name': '还在', 'channel': 'builtin', 'acts': man_acts}
    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    if os.path.exists(DEST):
        os.remove(DEST)
    # ★ 必须 ZIP_STORED（不压缩）：App 那边只认「不压缩」的条目，读到就解码。
    with zipfile.ZipFile(DEST, 'w', zipfile.ZIP_STORED) as z:
        z.writestr('act.json', json.dumps(man, ensure_ascii=False, indent=1))
        for a in man_acts:
            d = os.path.join(OUT, 'acts', a['name'])
            for f in sorted(os.listdir(d)):
                z.write(os.path.join(d, f), 'acts/%s/%s' % (a['name'], f))
    mb = os.path.getsize(DEST) / 1024 / 1024
    print('→ %s  (%.1f MB)' % (os.path.normpath(DEST), mb))


if __name__ == '__main__':
    k, fw, fh, ox, oy = plan()
    build(k, fw, fh, ox, oy, check_only='--check' in sys.argv)
