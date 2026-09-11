#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Still · 画中画小窗素材流水线
================================
把「带透明通道的动作视频」叠到「房间底图」上，产出小窗能直接播的方形 mp4。

素材  D:/素材/动作/<动作>/<动作>-1.mov     3840x2160 60fps argb 透明
底图  Tools/out/pip/room_bg.png            程序生成的占位空房间（换真素材只换这一张）
产出  Tools/out/pip/<动作>.mp4              720x720 30fps h264

用法
  python _pip_compose.py probe     抽查位：每段抽一帧算 bbox → placement.json + 对照图
  python _pip_compose.py build     按 placement.json 合成全部片段
  python _pip_compose.py sheet     拼演示时间线（空房 → 它在 → 空房 …）
"""
import os
import sys
import json
import glob
import math
import subprocess

import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = 'D:/素材/动作'
OUT = os.path.join(ROOT, 'out', 'pip')
TMP = os.path.join(ROOT, 'out', 'pip_tmp')
EXE = imageio_ffmpeg.get_ffmpeg_exe()

CANVAS = 720          # 方形画布边长
FPS = 30              # 小窗 30fps 足够
CAT_H_RATIO = 0.56    # 猫在方画布里的高度占比
GROUND_RATIO = 0.80   # 地面线（猫脚落在哪）
BG = os.path.join(OUT, 'room_bg.png')
PLACEMENT = os.path.join(TMP, 'placement.json')


# --------------------------------------------------------------------------
# 0. 占位空房间底图
# --------------------------------------------------------------------------
def make_bg():
    """程序生成的占位房间。以后换成真素材，直接覆盖 room_bg.png 即可。"""
    S = CANVAS
    im = Image.new('RGB', (S, S), '#F2E8DC')
    d = ImageDraw.Draw(im)

    G = int(S * GROUND_RATIO)

    # 墙：上浅下深一点点，做出角落的柔和明暗
    for y in range(0, G):
        t = y / max(1, G)
        c = (int(242 - 10 * t), int(232 - 10 * t), int(220 - 10 * t))
        d.line([(0, y), (S, y)], fill=c)

    # 地板
    d.rectangle([0, G, S, S], fill='#E3D2BB')
    d.line([(0, G), (S, G)], fill='#CDB79A', width=2)
    # 地板上的板缝
    for i in range(1, 4):
        x = int(S * i / 4)
        d.line([(x, G), (int(x - S * 0.06), S)], fill='#DAC8B0', width=1)

    # 猫落地的软影
    sh = Image.new('L', (S, S), 0)
    ds = ImageDraw.Draw(sh)
    ds.ellipse([int(S * 0.22), G - 14, int(S * 0.78), G + 26], fill=90)
    sh = sh.filter(ImageFilter.GaussianBlur(14))
    im.paste(Image.new('RGB', (S, S), '#B69C7A'), (0, 0), sh)

    # 窗（左上）
    wx0, wy0, wx1, wy1 = int(S * 0.09), int(S * 0.12), int(S * 0.37), int(S * 0.44)
    d.rectangle([wx0 - 4, wy0 - 4, wx1 + 4, wy1 + 4], fill='#E9DCC9')
    d.rectangle([wx0, wy0, wx1, wy1], fill='#D9E6EC')
    d.rectangle([wx0, wy0, wx1, wy1], outline='#C9B49A', width=4)
    d.line([(wx0 + wx1) // 2, wy0, (wx0 + wx1) // 2, wy1], fill='#C9B49A', width=3)
    d.line([wx0, (wy0 + wy1) // 2, wx1, (wy0 + wy1) // 2], fill='#C9B49A', width=3)

    # 坐垫（右侧地面）
    cx, cy = int(S * 0.74), int(G + S * 0.055)
    d.ellipse([cx - 78, cy - 26, cx + 78, cy + 26], fill='#D8C1A2')
    d.ellipse([cx - 78, cy - 32, cx + 78, cy + 14], fill='#E0CBB0')
    d.arc([cx - 78, cy - 32, cx + 78, cy + 14], 180, 360, fill='#C9AF8C', width=2)

    # 墙上一小片暖光
    gl = Image.new('L', (S, S), 0)
    dg = ImageDraw.Draw(gl)
    dg.polygon([(wx1 + 10, wy1), (int(S * 0.86), wy1 + 40), (int(S * 0.92), G), (wx1 + 40, G)],
               fill=42)
    gl = gl.filter(ImageFilter.GaussianBlur(30))
    im.paste(Image.new('RGB', (S, S), '#FFE9C6'), (0, 0), gl)

    os.makedirs(OUT, exist_ok=True)
    im.save(BG)
    return BG


# --------------------------------------------------------------------------
# 1. probe：抽帧 → 算猫在画面里的位置
# --------------------------------------------------------------------------
def _dur(mv):
    err = subprocess.run([EXE, '-i', mv], capture_output=True, text=True,
                         errors='ignore').stderr
    for ln in err.splitlines():
        if 'Duration:' in ln:
            t = ln.split('Duration:')[1].split(',')[0].strip()
            h, m, s = t.split(':')
            return float(h) * 3600 + float(m) * 60 + float(s)
    return 0.0


def probe():
    os.makedirs(TMP, exist_ok=True)
    make_bg()
    data = {}
    for dname in sorted(os.listdir(SRC)):
        p = os.path.join(SRC, dname)
        if not os.path.isdir(p):
            continue
        movs = sorted(glob.glob(os.path.join(p, '*.mov')))
        if not movs:
            continue
        mv = movs[0]
        dur = _dur(mv)
        t = dur / 3.0                      # 取 1/3 处，避开开头静止段
        f = os.path.join(TMP, dname + '.png')
        subprocess.run([EXE, '-y', '-ss', '%.2f' % t, '-i', mv,
                        '-frames:v', '1', f], capture_output=True)

        im = Image.open(f).convert('RGBA')
        W, H = im.size
        bb = im.split()[3].getbbox() or (0, 0, W, H)
        bw, bh = bb[2] - bb[0], bb[3] - bb[1]
        data[dname] = {
            'src': mv.replace('\\', '/'),
            'dur': round(dur, 2),
            'frame': [W, H],
            'bbox': list(bb),
            # 猫在**原画**里的相对位置 —— 用来判断各段是不是同一机位
            'cx': round((bb[0] + bb[2]) / 2 / W, 4),
            'bottom': round(bb[3] / H, 4),
            'h_ratio': round(bh / H, 4),
            'w_ratio': round(bw / W, 4),
        }
        print('%-10s %dx%d  dur=%5.2fs  猫高占比=%.2f  中心x=%.2f  底边=%.2f'
              % (dname, W, H, dur, bh / H, (bb[0] + bb[2]) / 2 / W, bb[3] / H))

    with open(PLACEMENT, 'w', encoding='utf-8') as fp:
        json.dump(data, fp, ensure_ascii=False, indent=2)
    print('\n→ %s' % PLACEMENT)
    return data


def load_placement():
    with open(PLACEMENT, encoding='utf-8') as fp:
        return json.load(fp)


# --------------------------------------------------------------------------
# 2. 摆位换算：把原画里的猫，放到方画布的指定位置
# --------------------------------------------------------------------------
REF = '坐立张望'          # 基准段：用它的坐姿定「猫多大、站哪儿」


def uniform_params(data, ref=REF):
    """整帧统一映射。

    各段是同一机位、同一只猫、大小一致 —— 所以不按各自的 bbox 对齐
    （那样换段时猫会跳一下），而是把每一帧都放进**同一个**缩放和偏移里。
    这样「它在左/它在右」是它真的在动，不是我们摆的。
    """
    rec = data.get(ref) or list(data.values())[0]
    W, H = rec['frame']
    bb = rec['bbox']
    sc = (CANVAS * CAT_H_RATIO) / (bb[3] - bb[1])
    cx = (bb[0] + bb[2]) / 2
    ox = CANVAS / 2 - cx * sc
    oy = CANVAS * GROUND_RATIO - bb[3] * sc
    return sc, ox, oy


def place(rec, uni=None):
    """返回 (缩放后整帧宽, 整帧高, overlay_x, overlay_y)。"""
    W, H = rec['frame']
    over = rec.get('over', {})

    if uni is None and over:
        # 单段覆盖：少数几段构图跟大部队不一样，单独定
        bb = rec['bbox']
        target_h = CANVAS * over.get('cat_h', CAT_H_RATIO)
        ground = CANVAS * over.get('ground', GROUND_RATIO)
        dx = CANVAS * over.get('dx', 0.0)
        sc = target_h / (bb[3] - bb[1])
        fw, fh = int(W * sc), int(H * sc)
        x = CANVAS / 2 + dx - (bb[0] + bb[2]) / 2 * sc
        y = ground - bb[3] * sc
        return fw, fh, int(x), int(y)

    if uni is None:
        return None                      # 由调用方传统一参数
    sc, ox, oy = uni
    if over:
        sc = sc * over.get('zoom', 1.0)
        ox += CANVAS * over.get('dx', 0.0)
        oy += CANVAS * over.get('dy', 0.0)
    return int(W * sc), int(H * sc), int(ox), int(oy)


# --------------------------------------------------------------------------
# 3. 合成：透明动作 + 底图 → 方形 mp4
# --------------------------------------------------------------------------
def build(only=None):
    os.makedirs(OUT, exist_ok=True)
    if not os.path.exists(BG):
        make_bg()
    data = load_placement()
    uni = uniform_params(data)
    print('统一映射：缩放 %.4f  偏移 (%d, %d)' % uni)
    done = []
    for name, rec in data.items():
        if only and name not in only:
            continue
        fw, fh, x, y = place(rec, uni)
        dst = os.path.join(OUT, name + '.mp4')
        dur = min(rec['dur'], 10.0)
        fc = (
            '[0:v]scale=%d:%d:flags=lanczos,format=rgba[cat];'
            '[1:v]scale=%d:%d,format=rgba[bg];'
            '[bg][cat]overlay=%d:%d:format=auto,format=yuv420p[v]'
            % (fw, fh, CANVAS, CANVAS, x, y)
        )
        r = subprocess.run(
            [EXE, '-y', '-i', rec['src'], '-loop', '1', '-i', BG,
             '-filter_complex', fc, '-map', '[v]',
             '-r', str(FPS), '-c:v', 'libx264', '-preset', 'veryfast',
             '-crf', '20', '-pix_fmt', 'yuv420p', '-t', '%.2f' % dur, dst],
            capture_output=True, text=True, errors='ignore')
        if r.returncode:
            print('FAIL %-10s %s' % (name, r.stderr[-300:]))
            continue
        mb = os.path.getsize(dst) / 1e6
        done.append((name, dur, mb))
        print('OK   %-10s %5.1fs  %5.2f MB' % (name, dur, mb))
    print('\n合计 %.1f MB' % sum(d[2] for d in done))
    return done


# --------------------------------------------------------------------------
# 4. 抽查位结果：把每段摆好后的样子拼成对照图
# --------------------------------------------------------------------------
def show(scale=260):
    data = load_placement()
    uni = uniform_params(data)
    bg = Image.open(BG).convert('RGB')
    tiles = []
    for name, rec in data.items():
        fw, fh, x, y = place(rec, uni)
        f = os.path.join(TMP, name + '.png')
        cat = Image.open(f).convert('RGBA')
        cat = cat.resize((fw, fh), Image.LANCZOS)
        canvas = bg.copy()
        canvas.paste(cat, (x, y), cat)
        d = ImageDraw.Draw(canvas)
        d.rectangle([0, 0, CANVAS - 1, CANVAS - 1], outline='#C9B79F', width=2)
        d.text((10, 8), name, fill='#6B5B4A')
        tiles.append(canvas.resize((scale, scale)))

    cols = 4
    rows = math.ceil(len(tiles) / cols)
    gap = 8
    sheet = Image.new('RGB', (cols * (scale + gap) + gap,
                              rows * (scale + gap) + gap), '#FFFFFF')
    for i, t in enumerate(tiles):
        sheet.paste(t, (gap + (i % cols) * (scale + gap),
                        gap + (i // cols) * (scale + gap)))
    p = os.path.join(OUT, 'placement_sheet.png')
    sheet.save(p)
    print('→ %s  %s' % (p, sheet.size))
    return p


# --------------------------------------------------------------------------
# 5. sheet：串演示时间线
# --------------------------------------------------------------------------
def _label(text, path):
    """底部一条半透明说明条 —— 让人一眼看懂这一刻是「它在」还是「它不在」。"""
    from PIL import ImageFont
    S = CANVAS
    im = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    band = int(S * 0.115)
    d.rectangle([0, S - band, S, S], fill=(28, 22, 18, 120))
    try:
        f = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 30)
    except Exception:
        f = ImageFont.load_default()
    d.text((26, S - band + (band - 34) // 2), text, font=f, fill=(255, 250, 242, 240))
    im.save(path)
    return path


def timeline(*picks):
    """把若干片段（含空房）拼成一条 mp4，用来验「它在 / 它不在」切换。"""
    if not picks:
        picks = [('__empty__', 3), ('坐立张望', 5), ('舔毛', 5),
                 ('__empty__', 3), ('走动', 5), ('趴下睡觉', 5), ('__empty__', 3)]
    files = []
    for i, (name, dur) in enumerate(picks):
        lab = _label('它不在 · 空房间' if name == '__empty__' else '它在 · ' + name,
                     os.path.join(TMP, 'lab_%d.png' % i))
        raw = os.path.join(TMP, 'seg_%d.mp4' % i)
        if name == '__empty__':
            subprocess.run(
                [EXE, '-y', '-loop', '1', '-i', BG, '-t', '%.2f' % dur,
                 '-r', str(FPS), '-c:v', 'libx264', '-preset', 'veryfast',
                 '-crf', '20', '-pix_fmt', 'yuv420p', raw],
                capture_output=True)
        else:
            src = os.path.join(OUT, name + '.mp4')
            if not os.path.exists(src):
                print('缺片段', name)
                continue
            subprocess.run(
                [EXE, '-y', '-i', src, '-i', lab, '-t', '%.2f' % dur,
                 '-filter_complex', '[0:v][1:v]overlay=0:0,format=yuv420p[v]',
                 '-map', '[v]', '-r', str(FPS), '-c:v', 'libx264',
                 '-preset', 'veryfast', '-crf', '20', raw],
                capture_output=True)
        # 空房也要贴上说明条
        if name == '__empty__':
            tagged = os.path.join(TMP, 'tag_%d.mp4' % i)
            subprocess.run(
                [EXE, '-y', '-i', raw, '-i', lab, '-t', '%.2f' % dur,
                 '-filter_complex', '[0:v][1:v]overlay=0:0,format=yuv420p[v]',
                 '-map', '[v]', '-r', str(FPS), '-c:v', 'libx264',
                 '-preset', 'veryfast', '-crf', '20', tagged],
                capture_output=True)
            raw = tagged
        files.append(raw)
    lst = os.path.join(TMP, 'concat.txt')
    with open(lst, 'w', encoding='utf-8') as fp:
        for f in files:
            fp.write("file '%s'\n" % f.replace('\\', '/'))
    out = os.path.join(OUT, 'demo_pip.mp4')
    subprocess.run([EXE, '-y', '-f', 'concat', '-safe', '0', '-i', lst,
                    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                    '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out],
                   capture_output=True)
    print('→ %s  %.1f MB' % (out, os.path.getsize(out) / 1e6))
    return out


# --------------------------------------------------------------------------
# 6. pack：挑干净段 + 生成空房 → 按英文名打包进 App 工程
# --------------------------------------------------------------------------
# 验收依据：Tools/out/hq/sheet_quality.png（每段抽 6 帧铺开，肉眼过一遍）
#
#   ✗ 下落 / 持续挣扎 / 挣扎2.0 / 被吐出 / 被吸入2
#       —— 带生成残留（白环、竖直残影、黑球运动模糊），进包会给用户看到，
#          但这几条**不能靠抠色去掉**（会连白下巴、白眼圈一起抠掉），只能等重做。
#   ✓ 其余干净。
#
# kind 的两种：
#   here  = 「它在这间房」时随机轮播的片段
#   cross = 穿进穿出用（悬空/被拎起），不进房间轮播，留给以后做落点之间的穿梭
#
# ★ 文件一律用英文名。中文名要横跨 Windows → git → macOS 三跳，
#   任何一处的编码处理不一致都会让 Xcode 找不到资源，而这类问题在 CI 上
#   表现为「编译过了但画面全黑」，极难查。名字在这里对齐一次就够了。
KEEP = [
    ('坐立张望',  'sit_look',   'here'),
    ('持续睡觉',  'sleep_curl', 'here'),
    ('趴下睡觉',  'sleep_flat', 'here'),
    ('睡醒起身',  'wake_up',    'here'),
    ('舔毛',      'groom',      'here'),
    ('走动',      'walk',       'here'),
    ('捕猎1',     'hunt1',      'here'),
    ('捕猎2',     'hunt2',      'here'),
    ('翻滚',      'roll',       'here'),
    ('被拎起',    'lifted',     'cross'),
    ('被拎起2.0', 'lifted2',    'cross'),
]

# 注意 ROOT 指的是 Tools/，App 工程在它上一层
APP_RES = os.path.normpath(os.path.join(ROOT, '..', 'Resources', 'pip'))
EMPTY_SECONDS = 8.0        # 空房循环一段，够长到不会被看出在循环


def pack():
    """把成品搬进 App 工程。只做复制，不重新编码 —— 它们已经是 720x720 h264。"""
    import shutil
    os.makedirs(APP_RES, exist_ok=True)

    # ① 空房：底图循环 8 秒。空房不是「没画面」，是「只有房间、没有猫」。
    empty = os.path.join(APP_RES, 'empty.mp4')
    subprocess.run([EXE, '-y', '-loop', '1', '-i', BG, '-t', str(EMPTY_SECONDS),
                    '-r', str(FPS), '-c:v', 'libx264', '-preset', 'slow',
                    '-crf', '20', '-pix_fmt', 'yuv420p',
                    '-movflags', '+faststart', empty], capture_output=True)
    total = os.path.getsize(empty)
    print('%-18s %7.0f KB   (empty · 空房间)' % ('empty.mp4', total / 1e3))

    # ② 动作段：直接搬
    for src_name, dst_name, kind in KEEP:
        src = os.path.join(OUT, src_name + '.mp4')
        if not os.path.exists(src):
            print('  缺：', src_name)
            continue
        dst = os.path.join(APP_RES, dst_name + '.mp4')
        shutil.copy2(src, dst)
        sz = os.path.getsize(dst)
        total += sz
        print('%-18s %7.0f KB   (%s · %s)' % (dst_name + '.mp4', sz / 1e3, kind, src_name))

    print('—— 合计 %.1f MB → %s' % (total / 1e6, APP_RES))
    return APP_RES


# --------------------------------------------------------------------------
if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'probe'
    if cmd == 'probe':
        probe()
    elif cmd == 'show':
        show()
    elif cmd == 'bg':
        print(make_bg())
    elif cmd == 'build':
        build(sys.argv[2:] or None)
    elif cmd == 'sheet':
        timeline()
    elif cmd == 'pack':
        pack()
    elif cmd == 'all':
        probe()
        build()
        show()
        timeline()
        pack()
    else:
        print(__doc__)
