#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 Resources/pip 里的视频片段生成 / 校验清单。

用法：
    python Tools/_pip_manifest.py            # 生成 MANIFEST.sha256（覆盖）
    python Tools/_pip_manifest.py --check    # 校验（CI 用，不一致就非零退出）

为什么需要这个东西
──────────────────
这 12 段 mp4 是画中画小窗唯一的内容。它们一旦被改坏，表现是**极难归因的**：

  · 文件还在，体积只差十几个字节 —— 看目录看不出来
  · 编译零报错、App 零日志 —— 看构建看不出来
  · 播放器只是「解不开」，不崩、不抛 —— 看运行也看不出来
  · 唯一的现象是**那间房整个空掉**，你会以为是 UI 写错了

实测踩过一次：推送脚本给所有文件做 CRLF→LF 规范化，把二进制里恰好出现的
0x0D 0x0A 一起吃掉，11 段全废，而每一道「素材在不在包里」的检查都显示正常。

所以这里存的是**内容指纹**（sha256），比对的是最终打进 ipa 的那几个文件 ——
从本地 → git → macOS 构建机 → zip → ipa 整条链路，任何一环改了字节都会红。
"""
import hashlib
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
PIP = os.path.join(ROOT, "Resources", "pip")
# 清单永远取自仓库，不跟着 --dir 走
MANIFEST = os.path.join(PIP, "MANIFEST.sha256")


def pick_src():
    """--dir 用来校验「另一个目录里的一堆同名 mp4」。

    典型用法是 CI：把最终打进 ipa 的那几段解出来，比对同一份清单 ——
    这样查的就不是「仓库里对不对」，而是「**手机上装到的那个包**里对不对」。
    """
    if "--dir" in sys.argv:
        return os.path.abspath(sys.argv[sys.argv.index("--dir") + 1])
    return PIP


SRC = pick_src()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def mp4_boxes_ok(path):
    """不做完整解码，只确认顶层 box 结构自洽、且 moov 在。

    被换行处理啃过的 mp4 会直接报 "moov atom not found" —— 这个便宜的检查
    就能抓住它，不需要装 ffmpeg。
    """
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 16 or data[4:8] != b"ftyp":
        return False
    off, n = 0, len(data)
    seen_moov = False
    while off + 8 <= n:
        size = int.from_bytes(data[off:off + 4], "big")
        typ = data[off + 4:off + 8]
        if size == 1:
            if off + 16 > n:
                return False
            size = int.from_bytes(data[off + 8:off + 16], "big")
        elif size == 0:
            size = n - off
        if size < 8 or off + size > n:
            return False
        if typ == b"moov":
            seen_moov = True
        off += size
    return seen_moov and off == n


def collect():
    out = []
    for name in sorted(os.listdir(SRC)):
        if name.lower().endswith(".mp4"):
            out.append(name)
    return out


def main():
    check = "--check" in sys.argv
    files = collect()
    if not files:
        sys.exit("Resources/pip 里一个 mp4 都没有")

    actual = {n: (sha256(os.path.join(SRC, n)), os.path.getsize(os.path.join(SRC, n)))
              for n in files}

    # 便宜的兜底：结构不对的根本不用比指纹
    broken_struct = [n for n in files if not mp4_boxes_ok(os.path.join(SRC, n))]

    if check:
        bad = []
        if not os.path.exists(MANIFEST):
            sys.exit("缺少 %s —— 先跑一次 python Tools/_pip_manifest.py" % MANIFEST)
        want = {}
        for line in open(MANIFEST, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            digest, name = line.split(None, 1)
            want[name.strip()] = digest
        for n, (d, _) in actual.items():
            if n not in want:
                bad.append("%s 不在清单里" % n)
            elif want[n] != d:
                bad.append("%s 内容对不上（清单 %s / 实际 %s）" % (n, want[n][:12], d[:12]))
        for n in want:
            if n not in actual:
                bad.append("%s 清单里有、包里没有" % n)
        bad += ["%s 结构就不对（moov 缺失）" % n for n in broken_struct]
        if bad:
            print("✗ 视频片段校验没过：")
            for b in bad:
                print("   ", b)
            sys.exit(1)
        print("✓ %d 段视频片段全部通过（指纹 + 结构）" % len(files))
        return

    if broken_struct:
        print("⚠ 这些片段结构就不对，先修好再生成清单：", ", ".join(broken_struct))
        sys.exit(1)

    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as f:
        f.write("# Resources/pip 的内容指纹。改了素材必须重跑 Tools/_pip_manifest.py。\n")
        f.write("# sha256<两个空格>文件名\n")
        for n in files:
            f.write("%s  %s\n" % (actual[n][0], n))
    print("✓ 写好 %s（%d 段）" % (os.path.relpath(MANIFEST, ROOT), len(files)))
    for n in files:
        print("   %-18s %8d B  %s" % (n, actual[n][1], actual[n][0][:16]))


if __name__ == "__main__":
    main()
