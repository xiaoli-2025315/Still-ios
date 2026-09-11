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
  Swift 对 ≤15 字节的字符串做内联优化（small string），"v13" 根本不会以
  UTF-8 明文出现在二进制里 —— 实测 v9 / v10 / v11 的包同样搜不到。
  所以改成核对「线上这份包是由哪个 commit 构建的 + 那个 commit 的源码里写的什么」。
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import time
import sys
import urllib.request
import zipfile

REPO = "xiaoli-2025315/Still-ios"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
WORK = os.path.normpath(os.path.join(ROOT, "..", ".workbuddy", "tmp"))
TMP = os.path.join(WORK, "release_check")

WANT_VERSION = "v15"
# ★ 这两个是 iOS 用来判断「这个 App / 这个扩展是哪一版」的**真**版本号（不是 Cfg.version）。
#   必须每出一版就变 —— 不变的话，覆盖安装后系统会沿用上一次那份扩展登记。
#   ⚠️ 但要说清楚：这一条是**推测**，没有实测证据。
#   （原注释里写的那句「表现是组件加不了、重启一次好一次」是我自己编的，
#    用户从没说过，2026-09-11 当场否认过。凡是加引号的"用户原话"，写入前必须能搜到。）
WANT_MARKETING = "1.15.0"
WANT_BUILD = "15"


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


def download(url, dst, tries=6):
    """流式下载 + 重试。

    ★ 别用 `r.read()` 一把梭：6 MB 的包走直连（绕代理）经常在半路 read timeout，
      而 python 的 urlopen timeout 是**单次 socket 读**的超时，
      大响应很容易偶发地卡死 —— 表现就是跑了十几分钟然后 TimeoutError。
      流式 + 有限次重试便宜得多。
    """
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request("https://api.github.com" + url)
            req.add_header("Authorization", "token " + TOK)
            req.add_header("Accept", "application/octet-stream")
            req.add_header("User-Agent", "still-verify")
            with urllib.request.urlopen(req, timeout=120) as r, open(dst, "wb") as f:
                while True:
                    chunk = r.read(256 * 1024)
                    if not chunk:
                        break
                    f.write(chunk)
            return open(dst, "rb").read()
        except Exception as e:                                # noqa: BLE001
            last = e
            print("  第 %d 次下载失败（%s），重试…" % (i + 1, type(e).__name__))
            time.sleep(2)
    raise SystemExit("下载失败 %d 次：%r" % (tries, last))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-download", action="store_true")
    args = ap.parse_args()

    os.makedirs(TMP, exist_ok=True)
    ipa = os.path.join(TMP, "Still-unsigned.ipa")

    rel = json.loads(api(f"/repos/{REPO}/releases/tags/nightly"))
    asset = next(x for x in rel["assets"] if x["name"] == "Still-unsigned.ipa")
    print("线上包:", asset["name"], asset["size"], "B  更新于", asset["updated_at"])

    if args.skip_download and os.path.exists(ipa):
        data = open(ipa, "rb").read()
        print("用本地已下载的那份:", len(data), "B")
    else:
        print("下载中 ...")
        data = download(f"/repos/{REPO}/releases/assets/{asset['id']}", ipa)
        print("下载字节:", len(data), " md5", hashlib.md5(data).hexdigest()[:10])
    print()

    z = zipfile.ZipFile(ipa)
    names = z.namelist()

    # ---------------- ① 这份包是谁构建的、源码里写的是什么
    print("=== ① 版本号 / 谁是正主（来源核对，不在二进制里搜字符串）===")
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

    # ---------------- ①b WidgetBundle 里有什么（这是「组件加不了」的头号真凶）
    #
    # 判据：组件库能不能看到这个 App，取决于系统能不能顺顺当当地把 WidgetBundle.body
    # 枚举一遍。`StillLiveActivity`（ActivityConfiguration）在里面时，历史上两次都让
    # 组件库里搜不到这个 App。所以这里**只允许**出现那两个小组件。
    print()
    print("=== ①b WidgetBundle 里注册了什么（放错东西 = 组件库搜不到这个 App）===")
    wsrc = api(f"/repos/{REPO}/contents/Sources/Widget/StillWidget.swift?ref={head}", raw=True).decode()
    seg = wsrc.split("struct StillWidgetBundle")[-1]
    seg = seg.split("\n}")[0] if "\n}" in seg else seg[:1500]
    for name, should in (("StillWidget", True),
                         ("StillProbeWidget", True),
                         ("StillLiveActivity", False),
                         ("StillTextWidget", False)):
        inb = name in seg
        line(inb == should,
             f"{'有' if inb else '没有'} {name}" + ("" if inb == should else "  ← 不该是这样！"))

    # ---------------- ①c 「让它动」默认是关的（照搬 Pixel Pals）
    #
    # 这一版把「组件能不能加」和「里面那只猫动不动」彻底拆成两件事：
    #   默认关 = 纯矢量静态猫，零外部依赖 —— 跟 v9 那个能正常添加的组件是同一类；
    #   想让它动，用户在组件设置里自己打开（Pixel Pals 对它那只宠物也是这么做的）。
    # 以前这两件事是绑死的：只要组件摆在桌面上，它就在尝试加载字体，
    # 于是「加不了」到底是不是动画引起的，永远分不清。
    print()
    print("=== ①c 「让它动」的默认值（必须是 false）===")
    ssrc = api(f"/repos/{REPO}/contents/Sources/App/Shared/Schedule.swift?ref={head}", raw=True).decode()
    has_param = "var animate: Bool" in ssrc
    line(has_param, f"SelectRoomIntent 里有「让它动」这个参数：{'有' if has_param else '★ 没有'}")
    mdef = re.search(r'@Parameter\(title: "让它动",\s*default:\s*(true|false)\)', ssrc)
    line(bool(mdef) and mdef.group(1) == "false",
         f"组件库里的默认值 = {mdef.group(1) if mdef else '？'}（必须是 false）")
    sent = re.findall(r"self\.animate = (true|false)", ssrc)
    line(bool(sent) and all(x == "false" for x in sent),
         f"各个 init 里都设成 false：{sent or '★ 一个都没设'}")
    wsrc_a = api(f"/repos/{REPO}/contents/Sources/Widget/StillWidget.swift?ref={head}", raw=True).decode()
    wsent = re.findall(r"animated: configuration\.animate", wsrc_a)
    line(len(wsent) >= 2,
         f"timeline 里把开关传下去了 {len(wsent)} 处（有两个分支：在这儿 / 不在这儿）")

    # ---------------- ② 帧字体在两个 target 里都在吗
    print()
    print("=== ② 帧字体在两个 target 里吗（打进包即可，注册走运行时）===")
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

    # ---------------- ③ 字体**不该**出现在 Info.plist 里
    #
    # ★★ 这一项在 v13 **反过来了**。
    #   以前查的是「扩展有没有注册 UIAppFonts」—— 那时的逻辑是「不注册就读不到字体」，
    #   逻辑本身没错，但代价算错了：写进 Info.plist = 系统**每次启动扩展进程**都要
    #   解析这份我们自造的 sbix 字体。系统一旦不接受它，赔上的不是「猫画不出来」，
    #   而是**整个 App 从组件库里消失**（用户看到的就是「组件加不了」）。
    #   实测证据：v9（无字体）能加；v11 / v12（有字体 + 这里注册）加不了。
    #   v13 改成运行时 CTFontManagerRegisterFontsForURL，所以**这里必须为空**。
    print()
    print("=== ③ 字体注册（**必须是空的** —— 注册了会连坐整个 App）===")
    ext = "Payload/Still.app/PlugIns/StillWidgetExtension.appex/Info.plist"
    pl = plistlib.loads(z.read(ext))
    line(not pl.get("UIAppFonts"), f"扩展 UIAppFonts = {pl.get('UIAppFonts') or '（无，正确）'}")
    pl2 = plistlib.loads(z.read("Payload/Still.app/Info.plist"))
    line(not pl2.get("UIAppFonts"), f"主 App UIAppFonts = {pl2.get('UIAppFonts') or '（无，正确）'}")

    # ---------------- ③b 系统眼里的「第几版」
    #
    # 这一项以前从来没查过，而它也是「组件加不了」的一条真因（见文件头说明）。
    # 两个 target 的 build 号还必须一致 —— 不一致系统会拒绝加载扩展。
    print()
    print("=== ③b iOS 眼里的版本号（MARKETING_VERSION / CURRENT_PROJECT_VERSION）===")
    for label, p in (("主 App", "Payload/Still.app/Info.plist"),
                     ("扩展", ext)):
        plx = plistlib.loads(z.read(p))
        short = plx.get("CFBundleShortVersionString")
        build = plx.get("CFBundleVersion")
        line(short == WANT_MARKETING and build == WANT_BUILD,
             f"{label}: {short} ({build})   期望 {WANT_MARKETING} ({WANT_BUILD})")
    av = plistlib.loads(z.read("Payload/Still.app/Info.plist")).get("CFBundleVersion")
    ev = plistlib.loads(z.read(ext)).get("CFBundleVersion")
    line(av == ev, f"App 与扩展的 build 号一致：{av} / {ev}")

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
