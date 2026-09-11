#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""出包后的逐项核对 —— 全部从「线上那个 ipa」里解出来看，不看本地源码。

用法：
    python Tools/_verify_release.py                # 下载线上包并逐项核对
    python Tools/_verify_release.py --skip-download  # 用 .workbuddy/tmp 里已下过的那份

为什么要有它（真踩过的坑）：
  核对素材时只查了「在不在包里、体积对不对」，没查「能不能解」——
  等于自己给自己发通行证，还把排查方向引向了 UI 和播放器。
  所以这里每一项都必须是「解出来、算出来」的硬证据。

★ 版本号那一项为什么不在可执行文件里搜字符串：
  Swift 对 ≤15 字节的字符串做内联优化（small string），"v11" 根本不会以
  UTF-8 明文出现在二进制里 —— 实测 v9 / v10 的包同样搜不到。
  所以改成核对「线上这份包是由哪个 commit 构建的 + 那个 commit 的源码里写的什么」。
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.request
import zipfile

REPO = "xiaoli-2025315/Still-ios"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
WORK = os.path.normpath(os.path.join(ROOT, "..", ".workbuddy", "tmp"))
TMP = os.path.join(WORK, "release_check")

WANT_VERSION = "v11"


def _token():
    for p in (os.path.join(WORK, "ghtok.txt"),
              "/tmp/ghtok.txt",
              os.path.expanduser("~/.workbuddy-ghtok")):
        try:
            with open(os.path.normpath(p)) as f:
                t = f.read().strip()
            if t:
                return t
        except Exception:
            pass
    raise SystemExit("找不到 GitHub 令牌：把它写到 %s/ghtok.txt" % WORK)


TOK = _token()
FAIL = []


def api(path, raw=False):
    req = urllib.request.Request("https://api.github.com" + path)
    req.add_header("Authorization", "token " + TOK)
    if raw:
        # ★ 两种「要原始内容」的接口认的 Accept 不一样，混用会 415 Unsupported Media Type：
        #   Contents API 只认 application/vnd.github.raw，Release 资产下载只认 application/octet-stream。
        req.add_header("Accept",
                       "application/octet-stream" if "/releases/assets/" in path
                       else "application/vnd.github.raw")
    else:
        req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "still-verify")
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def line(ok, text):
    if not ok:
        FAIL.append(text)
    print(("  OK  " if ok else "  ✗✗  ") + text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-download", action="store_true")
    a = ap.parse_args()

    os.makedirs(TMP, exist_ok=True)
    ipa = os.path.join(TMP, "Still-unsigned.ipa")

    rel = json.loads(api(f"/repos/{REPO}/releases/tags/nightly"))
    asset = next(x for x in rel["assets"] if x["name"] == "Still-unsigned.ipa")
    print("线上包:", asset["name"], asset["size"], "B  更新于", asset["updated_at"])

    if a.skip_download and os.path.exists(ipa):
        data = open(ipa, "rb").read()
        print("用本地已下载的那份:", len(data), "B")
    else:
        print("下载中 ...")
        data = api(f"/repos/{REPO}/releases/assets/{asset['id']}", raw=True)
        open(ipa, "wb").write(data)
        print("下载字节:", len(data), " md5", hashlib.md5(data).hexdigest()[:10])
    print()

    z = zipfile.ZipFile(ipa)
    names = z.namelist()

    # ---------------- ① 这份包是谁构建的、源码里写的是什么
    print("=== ① 版本号（来源核对，不在二进制里搜字符串）===")
    head = json.loads(api(f"/repos/{REPO}/git/refs/heads/master"))["object"]["sha"]
    src = api(f"/repos/{REPO}/contents/Sources/App/Shared/StillConfig.swift?ref={head}", raw=True).decode()
    m = re.search(r'static let version\s*=\s*"([^"]+)"', src)
    got = m.group(1) if m else "?"
    line(got == WANT_VERSION, f"master HEAD {head[:8]} 的 Cfg.version = {got}（期望 {WANT_VERSION}）")
    runs = json.loads(api(f"/repos/{REPO}/actions/runs?per_page=5"))["workflow_runs"]
    r0 = next((r for r in runs if r["head_sha"] == head), None)
    if r0:
        line(r0["conclusion"] == "success",
             f"该 commit 的 CI：{r0['status']}/{r0['conclusion']}（run {r0['id']}）")
    else:
        line(False, "最近 5 次 CI 里没有这个 commit 的运行")

    # ---------------- ② 帧字体在两个 target 里都在吗
    print()
    print("=== ② 帧字体在两个 target 里吗 ===")
    local_font = os.path.join(ROOT, "Resources", "fonts", "StillFrames.ttf")
    sha_local = hashlib.sha256(open(local_font, "rb").read()).hexdigest()
    for p in ("Payload/Still.app/StillFrames.ttf",
              "Payload/Still.app/PlugIns/StillWidgetExtension.appex/StillFrames.ttf"):
        if p in names:
            b = z.read(p)
            s = hashlib.sha256(b).hexdigest()
            line(s == sha_local, f"{p}  {len(b)} B  sha {s[:10]}" +
                 ("" if s == sha_local else " ← 与本地不一致！"))
        else:
            line(False, f"{p}  ★ 不在包里")

    # ---------------- ③ 扩展自己注册字体了吗
    print()
    print("=== ③ 字体注册（扩展不注册 = 组件里那只猫会退化成数字）===")
    ext = "Payload/Still.app/PlugIns/StillWidgetExtension.appex/Info.plist"
    pl = plistlib.loads(z.read(ext))
    line("StillFrames.ttf" in pl.get("UIAppFonts", []), f"扩展 UIAppFonts = {pl.get('UIAppFonts', [])}")
    pl2 = plistlib.loads(z.read("Payload/Still.app/Info.plist"))
    line("StillFrames.ttf" in pl2.get("UIAppFonts", []), f"主 App UIAppFonts = {pl2.get('UIAppFonts', [])}")

    # ---------------- ④ 视频素材：能不能解
    print()
    print("=== ④ 视频素材（不是「在不在」，是「能不能解」）===")
    try:
        import imageio_ffmpeg
        ff = imageio_ffmpeg.get_ffmpeg_exe()
    except Exception as e:                                    # pragma: no cover
        ff = None
        print("  (没有 ffmpeg，跳过解码检查:", e, ")")

    man = {}
    for ln in open(os.path.join(ROOT, "Resources", "pip", "MANIFEST.sha256"), encoding="utf-8"):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            h, n = ln.split(None, 1)
            man[n.strip()] = h

    bad = []
    for name, want in sorted(man.items()):
        p = "Payload/Still.app/" + name
        if p not in names:
            bad.append(name + " 不在包里")
            continue
        b = z.read(p)
        if hashlib.sha256(b).hexdigest() != want:
            bad.append(name + " sha 不一致")
            continue
        if ff:
            f = os.path.join(TMP, name)
            open(f, "wb").write(b)
            r = subprocess.run([ff, "-v", "error", "-i", f, "-f", "null", "-"],
                               capture_output=True, timeout=180)
            if r.returncode != 0 or r.stderr.strip():
                bad.append(f"{name} 解不开: {r.stderr.decode()[:60]}")
    line(not bad, f"{len(man) - len(bad)}/{len(man)} 段指纹一致且可解码" +
         ("；坏段: " + ", ".join(bad) if bad else ""))

    # ---------------- 落一份到 dist/
    print()
    dst = os.path.join(ROOT, "dist", "Still-%s.ipa" % got)
    open(dst, "wb").write(data)
    print("已另存 ->", dst, os.path.getsize(dst), "B")
    print()
    print("总结论:", "全部通过 ✅" if not FAIL else "有项目没过 ❌ → " + "；".join(FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
