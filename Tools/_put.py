#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本地文件推到 GitHub（Contents API）。

跟 _push_api.py 的区别：令牌从环境变量 / 缓存文件读，不再调 `git credential fill`
—— 那个 subprocess 在代理环境下会卡死（实测卡 7 分钟无输出）。

用法： python Tools/_put.py <file1> [file2 ...] [-m "commit message"]
"""
import base64, json, os, subprocess, sys, urllib.request, urllib.error

REPO = "xiaoli-2025315/Still-ios"
BRANCH = "master"
API = "https://api.github.com"
TOK = (os.environ.get("GITHUB_TOKEN") or "").strip()
if not TOK:
    raise SystemExit("需要令牌：先在 bash 里跑\n"
                     "  TOK=$(printf 'protocol=https\\nhost=github.com\\n\\n' | "
                     "git credential fill | grep '^password=' | cut -d= -f2-)\n"
                     "然后 export GITHUB_TOKEN 再执行本脚本")

MSG = "update"
args = []
i = 1
while i < len(sys.argv):
    if sys.argv[i] == "-m":
        MSG = sys.argv[i + 1]; i += 2
    else:
        args.append(sys.argv[i]); i += 1


def git_bytes(p):
    """交给 git 决定这个文件该存成什么字节，再把它实际存下来的原始字节取出来。

    ★★ 这里**绝对不能**自己 `replace(b"\\r\\n", b"\\n")`。
       文本文件那样做是对的（本地 CRLF、CI 侧 LF），但二进制素材
       （mp4 / png / 字体）里恰好出现的 0x0D 0x0A 会被一起吃掉。
       后果极其隐蔽：文件还在、体积只差十几个字节、编译零报错、真机日志空白，
       只有画面是黑的 —— 播放器解不开。
       实测踩过：11 个 mp4 全被吃掉几十字节，App 里那间房整个空掉。

    走 `git hash-object` 的好处是：它按 .gitattributes 与二进制启发式判定，
    跟我们本地 `git commit` 的结果**逐字节一致**，再也不会出现「本地能解码、
    远端传上去是坏的」这种两套真相。

    前提：这个文件已经被 git 跟踪，或者至少 `git hash-object --path` 能读到它。
    """
    sha = subprocess.run(["git", "hash-object", "-w", "--path", p, p],
                         capture_output=True, text=True).stdout.strip()
    if not sha:
        # 兜底：git 不可用时按原始字节上传（宁可原样，也不要自己改字节）
        return open(p, "rb").read()
    return subprocess.run(["git", "cat-file", "blob", sha],
                          capture_output=True).stdout


def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(API + path, data=data, method=method, headers={
        "Authorization": "Bearer " + TOK,
        "Accept": "application/vnd.github+json",
        "User-Agent": "py",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.load(resp)


for p in args:
    raw = git_bytes(p)
    b64 = base64.b64encode(raw).decode()
    api_path = f"/repos/{REPO}/contents/{p}?ref={BRANCH}"
    sha = None
    try:
        sha = req("GET", api_path)["sha"]
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print("GET fail", p, e.code, e.read()[:200]); sys.exit(1)
    body = {"message": MSG, "content": b64, "branch": BRANCH}
    if sha:
        body["sha"] = sha
    req("PUT", api_path, body)
    print("pushed", p, len(raw), "bytes")
