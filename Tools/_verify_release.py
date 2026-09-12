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
import struct
import time
import sys
import urllib.request
import zipfile

REPO = "xiaoli-2025315/Still-ios"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
WORK = os.path.normpath(os.path.join(ROOT, "..", ".workbuddy", "tmp"))
TMP = os.path.join(WORK, "release_check")

WANT_VERSION = "v23"
# ★ 这两个是 iOS 用来判断「这个 App / 这个扩展是哪一版」的**真**版本号（不是 Cfg.version）。
#   必须每出一版就变 —— 不变的话，覆盖安装后系统会沿用上一次那份扩展登记。
WANT_MARKETING = "1.23.0"
WANT_BUILD = "23"


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
    # 版本证据 = StillWidget.swift 里写死的组件显示名（Cfg.version 从 v20 起不存在）。
    wsrc0 = api(f"/repos/{REPO}/contents/Sources/Widget/StillWidget.swift?ref={head}", raw=True).decode()
    got = "v23" if "还在 v23 · 猫" in wsrc0 else "?"
    line(got == WANT_VERSION, f"master HEAD {head[:8]} 的组件显示名 = 还在 {got}（期望 {WANT_VERSION}）")
    runs = json.loads(api(f"/repos/{REPO}/actions/runs?per_page=5"))["workflow_runs"]
    r0 = next((r for r in runs if r["head_sha"] == head), None)
    if r0:
        line(r0["conclusion"] == "success",
             f"该 commit 的 CI：{r0['status']}/{r0['conclusion']}（run {r0['id']}）")
    else:
        line(False, "最近 5 次 CI 里没有这个 commit 的运行")

    # ---------------- ①b WidgetBundle 里有什么
    #
    # ★★ 这一节的期望值在 v16 **整个翻过来了**，因为以前那条判据是错的。
    #
    #   旧判据：「`StillLiveActivity` 在 bundle 里 → 组件库搜不到这个 App」，
    #   还据此在 a06f420 把它移出了 bundle。
    #   推翻它的硬事实：**v9 的 bundle 里就有 `StillLiveActivity()`，而 v9 是能加组件的**
    #   （v9 = commit b85bea4e9b，逐行核对过）。
    #   所以灵动岛在不在 bundle 里，跟「能不能加」**无关** —— 别再往这个方向查。
    #
    #   v16 的期望 = **v9 那个 bundle 原样**：StillWidget + StillTextWidget + StillLiveActivity。
    #   v13 加的 `StillProbeWidget` 不在里面（v9 没有它，先去掉，少一个变量）。
    print()
    print("=== ①b WidgetBundle 里注册了什么（期望 = v9 那三个）===")
    wsrc = api(f"/repos/{REPO}/contents/Sources/Widget/StillWidget.swift?ref={head}", raw=True).decode()
    seg = wsrc.split("struct StillWidgetBundle")[-1]
    seg = seg.split("\n}")[0] if "\n}" in seg else seg[:1500]
    for name, should in (("StillWidget", True),
                         ("StillTextWidget", True),
                         ("StillLiveActivity", True),
                         ("StillProbeWidget", False)):
        inb = name in seg
        line(inb == should,
             f"{'有' if inb else '没有'} {name}" + ("" if inb == should else "  ← 不该是这样！"))

    # ---------------- ①c 扩展侧**完全不碰**帧字体（v16 = v9 形态）
    #
    #   v9 → v15 之间，扩展里唯一实质性的新东西就是那份自造的 sbix 字体（让猫逐帧动）。
    #   时间线对得很整齐：**v9 没有它、能加；v11 起有它、加不了。**
    #
    #   v16 要先把「能加」拿回来，所以扩展这一侧连字体文件都不放
    #   （project.yml 里也拿掉了 `Resources/fonts`）——
    #   **不放文件，就不存在「系统解析这份字体时出事」这条路径。**
    #   猫暂时是 v9 那套矢量静态猫（CatView）：一样有猫，只是不逐帧动。
    print()
    print("=== ①c 扩展应该是 v9 形态（不碰字体 / 没有动画代码）===")
    for bad, why in (("CatFont", "帧字体加载器"),
                     ("StillFrames", "字体文件名"),
                     ("animated", "动画开关"),
                     ("Ticking", "每秒翻页的计时器"),
                     ("CTFontManager", "运行时注册字体"),
                     ("currentConfigurations", "跨进程问系统要组件配置")):
        n = wsrc.count(bad)
        line(n == 0, f"扩展源码里没有 {bad}（{why}）：{n} 处" +
             ("" if n == 0 else "  ← 不该有！"))

    # ---------------- ①d 源码与 v9 逐字节（v20 立下的硬校验）
    #
    #   v20 = 原封不动 v9。v21 起只允许两个文件离开 v9：
    #     · StillWidget.swift —— 「它在这儿」卡换成静态猫图（v21 补丁）
    #     · project.yml       —— 版本号 + 扩展挂 Resources/widget（v20/v21 补丁）
    #   其余 10 个文件有一个字节不一样就红。
    print()
    print("=== ①d 源码与 v9（b85bea4e9b）逐字节一致（v21 豁免 StillWidget/project.yml）===")
    V9_SHA = "b85bea4e9b"
    v9tree = {i["path"]: i["sha"] for i in
              json.loads(api(f"/repos/{REPO}/git/trees/{V9_SHA}?recursive=1"))["tree"]
              if i["type"] == "blob"}
    V9_FILES = [
        "Sources/App/ContentView.swift",
        "Sources/App/Panel/StatusPanelView.swift",
        "Sources/App/PiP/Notifier.swift",
        "Sources/App/PiP/PiPController.swift",
        "Sources/App/Shared/PetEngine.swift",
        "Sources/App/Shared/RoomScope.swift",
        "Sources/App/Shared/Schedule.swift",
        "Sources/App/Shared/SharedStore.swift",
        "Sources/App/Shared/StillConfig.swift",
        "Sources/App/Shared/TalkToCatIntent.swift",
    ]
    for p in V9_FILES:
        now = json.loads(api(f"/repos/{REPO}/contents/{p}?ref={head}"))
        line(now["sha"] == v9tree[p], f"{p.split('/')[-1]}  与 v9 相同")
    wsw = json.loads(api(f"/repos/{REPO}/contents/Sources/Widget/StillWidget.swift?ref={head}"))
    line(wsw["sha"] != v9tree["Sources/Widget/StillWidget.swift"],
         "StillWidget.swift 与 v9 不同（应该的：v21 起组件 = 大猫图）")
    line(wsrc0.count("Image(\"cat_sit\")") >= 1, "组件本体是大猫图 cat_sit")
    # ★ 数代码不数注释：断言曾被源码注释里的 "PawMark" 触发过假报警（v15 的教训）。
    wsrc_code = "\n".join(l.split("//")[0] for l in wsrc0.split("\n"))
    line("PawMark" not in wsrc_code, "小爪印已从组件代码里撤掉（v22）")
    # 「它现在在」只允许留在排障用的文字组件里（plainAway）；
    # 「待了」（在/here 卡）应彻底消失。组件本体（catFull）没有任何说明文字。
    line(wsrc_code.count("它现在在") == 1 and "待了" not in wsrc_code,
         "卡片版式的说明文字已拿掉（只剩排障组件那 1 处）")
    pyml = json.loads(api(f"/repos/{REPO}/contents/project.yml?ref={head}"))
    line(pyml["sha"] != v9tree["project.yml"],
         "project.yml 与 v9 不同（应该的：版本号 1.23.0/23 + 扩展挂 Resources/widget）")
    rsrc = json.loads(api(f"/repos/{REPO}/contents/Resources/widget/cat_sit.png?ref={head}"))
    line(rsrc["size"] == 46814, f"Resources/widget/cat_sit.png 在库里（{rsrc['size']} B）")

    # ---------------- ② 帧字体：**扩展里必须没有**（主 App 里有也无所谓）
    #
    #   v11~v15 这里查的是「字体在两个 target 里都在吗」。v16 反过来：
    #   扩展那一侧**不许有** —— 有，就意味着系统启动扩展时可能去解析它，
    #   而那正是「v9 能加、v11 起加不了」唯一对得上的变量。
    #   主 App 里有一份不算事：主 App 不注册它（UIAppFonts 为空），不会去解析。
    print()
    print("=== ② 扩展包里没有帧字体（v16 形态）===")
    wfont = "Payload/Still.app/PlugIns/StillWidgetExtension.appex/StillFrames.ttf"
    has_w = wfont in names
    line(not has_w, "扩展包里没有 StillFrames.ttf" +
         ("" if not has_w else f"  ← 不该有（{len(z.read(wfont))} B）！"))
    appfont = "Payload/Still.app/StillFrames.ttf"
    if appfont in names:
        print(f"  ·   主 App 里有一份（{len(z.read(appfont))} B）—— 无害，主 App 不注册它")
    else:
        print("  ·   主 App 里也没有（字体已从打包链路摘干净）")

    # ---------------- ②b 静态猫图：必须真的进了扩展包（v21）
    #
    #   资源放错 buildPhase 会「编译全绿但包里没有」（PiP 视频踩过同一坑），
    #   所以必须从最终 ipa 里解出来看，不看配置写了什么。
    #   ★ 不能按字节比：Xcode 打包会把 PNG 重编码成 Apple 私有 CgBI 格式
    #     （CopyPNGFile，字节变、像素不变）—— 这里改验「chunk 结构 + 尺寸」。
    print()
    print("=== ②b 扩展包里有静态猫图 cat_sit.png（验尺寸，不验字节）===")
    wimg = "Payload/Still.app/PlugIns/StillWidgetExtension.appex/cat_sit.png"
    if wimg not in names:
        line(False, "扩展包里没有 cat_sit.png  ← 图没进打包链路，组件里会是空白！")
    else:
        pb = z.read(wimg)
        w = h = None
        cgbi = pb[8:12] == b"CgBI"
        off = 8
        while off < len(pb) - 8:
            ln = struct.unpack(">I", pb[off:off + 4])[0]
            typ = pb[off + 4:off + 8]
            if typ == b"IHDR":
                w, h = struct.unpack(">II", pb[off + 8:off + 16])
                break
            off += 12 + ln
        line((w, h) == (172, 230),
             f"cat_sit.png 在扩展包里：{len(pb)} B，CgBI={'是' if cgbi else '否'}，尺寸 {w}x{h}（期望 172x230）")

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

    # ---------------- ③b-2 身份（v19 换了全新 bundle id）
    #
    #   v9 能加、v10 起搜不到，把代码层面能对上的差异全部消完（v16 回退源码、
    #   v17 设备类型、v18 隔离 ActivityKit/WidgetCenter）仍然搜不到。
    #   剩下唯一没换过的就是**身份本身** —— iOS 按 bundle id 记「这个 App 有哪些扩展」，
    #   旧身份的登记一旦坏了，覆盖安装永远洗不掉。
    #   v19 起用全新身份，让系统当从没见过的 App 重新登记。
    #   ★ 身份是签名 / 登记 / App Group 的根，今后不许随手改；要改必须整组一起改：
    #     主 App id / 扩展 id（= 主 id + .widget）/ App Group / 核验断言。
    # ★ 真实规则：bundle id = bundleIdPrefix + target 名（XcodeGen 拼的）。
    #   `productBundleIdentifier:` 那种写法不存在，写了也会被静默忽略。
    # ★ 循环变量叫 bid，不许叫 got —— 上面 ① 里 got 存的是版本号，
    #   这里盖掉它的话，最后 dist 文件名会变成 Still-com.still.…ipa（真踩过）。
    print()
    print("=== ③b-2 身份（bundle id）===")
    WANT_APPID = "com.still.Still"
    WANT_EXTID = "com.still.StillWidgetExtension"
    for label, p, want in (("主 App", "Payload/Still.app/Info.plist", WANT_APPID),
                           ("扩展", ext, WANT_EXTID)):
        bid = plistlib.loads(z.read(p)).get("CFBundleIdentifier")
        line(bid == want, f"{label} bundle id = {bid}" +
             ("" if bid == want else f"  ← 期望 {want}！"))
    av = plistlib.loads(z.read("Payload/Still.app/Info.plist")).get("CFBundleVersion")
    ev = plistlib.loads(z.read(ext)).get("CFBundleVersion")
    line(av == ev, f"App 与扩展的 build 号一致：{av} / {ev}")

    # ---------------- ③c 设备类型：**必须是纯 iPhone（[1]）**
    #
    #   `settings.base` 里写 `TARGETED_DEVICE_FAMILY: "1"` **没用** —— XcodeGen 生成
    #   Info.plist 时给的是默认值 `[1, 2]`（iPhone + iPad）。
    #   必须在两个 target 的 `info.properties` 里显式写 `UIDeviceFamily: [1]`。
    #
    #   声明成 [1, 2]，系统就把这个 App 当通用 App；小组件在 iPhone 的组件库里
    #   不会被算作「为 iPhone 主屏幕优化」的那一批 —— 表现就是搜不到、加不了。
    print()
    print("=== ③c 设备类型（必须是 [1] = 纯 iPhone）===")
    for label, p in (("主 App", "Payload/Still.app/Info.plist"),
                     ("扩展", ext)):
        fam = plistlib.loads(z.read(p)).get("UIDeviceFamily")
        line(fam == [1], f"{label} UIDeviceFamily = {fam}（期望 [1]）")

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
