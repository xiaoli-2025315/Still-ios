#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
完全无 git CLI 的提交通道 —— git push 走不通时用 GitHub Git Database API。

用法：
  python Tools/_push_full.py <文件1> <文件2> ... [-m "提交说明"]

原理：
  Contents API（之前那个）只更新文件，git tree object 不变 → CI 看到的是旧代码。
  Git Database API 可以构造出真正的 commit、tree、blob 对象，CI 会按 commit 触发。

流程：
  1. 从 git credential 拿令牌
  2. GET 拿 master 当前 commit → 它的 tree
  3. 对每个变更文件：算本地 blob sha（git hash-object），POST 创建/获取 blob
  4. 构造新 tree：基于旧 tree，把目标 path 指向新 blob
  5. POST 新 commit（带 parent）
  6. PATCH 把 master ref 指到新 commit
"""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "xiaoli-2025315/Still-ios"
BRANCH = "master"
API = "https://api.github.com"


def token() -> str:
    """按「先便宜后昂贵」的顺序找令牌。

    ★ 为什么不再一上来就 `git credential fill`：
      代理环境下那个 subprocess 会卡死（实测卡 7 分钟没有任何输出，
      因为 credential-manager 弹了 GUI 在等人工输入）。
      `_put.py` 的文档里早就记过这个坑，这里当年没同步改。
    """
    tok = (os.environ.get("GITHUB_TOKEN") or "").strip()
    if tok:
        return tok

    # ★ /tmp 在不同沙箱里**可能不是同一个 /tmp**（实测：同一个命令，
    #   前台能看到 /tmp/ghtok.txt，后台任务看不到）。所以多找几个地方，
    #   并且绝对不要「找不到就退回 git credential fill」——
    #   那个会弹 GUI，父进程被 kill 后孙子进程还攥着管道，
    #   subprocess 的 timeout 也救不回来，表现是**整个脚本无限期挂住**。
    for cached in (
        "/tmp/ghtok.txt",
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "..", ".workbuddy", "tmp", "ghtok.txt"),
        os.path.expanduser("~/.workbuddy-ghtok"),
    ):
        try:
            with open(os.path.normpath(cached)) as f:
                tok = f.read().strip()
            if tok:
                return tok
        except OSError:
            continue

    try:
        out = subprocess.run(
            ["git", "credential", "fill"],
            input="protocol=https\nhost=github.com\n\n",
            capture_output=True, text=True, timeout=20,
        ).stdout
    except subprocess.TimeoutExpired:
        raise SystemExit(
            "git credential fill 超时（代理环境常见）。\n"
            "先把令牌落到 /tmp/ghtok.txt，或 export GITHUB_TOKEN 再跑：\n"
            "  echo '<token>' > /tmp/ghtok.txt")
    for line in out.splitlines():
        if line.startswith("password="):
            return line[len("password="):].strip()
    raise SystemExit("拿不到令牌")


def req(method: str, url: str, tok: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", f"Bearer {tok}")
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "still-push-full")
    if data:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        print(f"HTTP {method} {url}: {e.code}", file=sys.stderr)
        print(e.read()[:500].decode(errors="replace"), file=sys.stderr)
        raise


def git_blob(path: str):
    """交给 git 决定这个文件该存成什么字节，再把实际存下来的原始字节取出来。

    返回 (sha, bytes)。

    ★★ 这里**绝对不能**自己 `raw.replace(b"\\r\\n", b"\\n")`。
       文本文件那样做是对的（本地 CRLF、CI 侧 LF），但二进制素材
       （mp4 / png / 字体）里恰好出现的 0x0D 0x0A 会被一起吃掉。
       后果极其隐蔽：文件还在、体积只差十几个字节、编译零报错、真机日志空白，
       只有画面是黑的 —— 播放器解不开。
       实测踩过：11 个 mp4 全被吃掉几十字节，App 里那间房整个空掉。

    走 `git hash-object -w --path` 的好处：它按 .gitattributes 与二进制启发式判定，
    结果跟我们本地 `git commit` **逐字节一致** —— 不会再有「本地能解码、
    推到远端是坏的」这种两套真相。
    """
    r = subprocess.run(["git", "hash-object", "-w", "--path", path, path],
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        # 兜底：git 不可用就直接按原始字节传（宁可原样，也不要自己改字节）
        with open(path, "rb") as f:
            data = f.read()
        sha = hashlib.sha1(
            b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        return sha, data
    sha = r.stdout.strip()
    data = subprocess.run(["git", "cat-file", "blob", sha],
                          capture_output=True).stdout
    return sha, data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="要提交的文件")
    ap.add_argument("-m", required=True, help="commit message")
    args = ap.parse_args()

    tok = token()

    # 1) 拿到 master 当前 head
    head = req("GET", f"{API}/repos/{REPO}/git/ref/heads/{BRANCH}", tok)
    head_sha = head["object"]["sha"]
    head_commit = req("GET", f"{API}/repos/{REPO}/git/commits/{head_sha}", tok)
    base_tree_sha = head_commit["tree"]["sha"]
    print(f"base tree: {base_tree_sha[:10]}")

    # 2) 处理每个文件
    new_trees_items = []  # 要替换或新增的 path/blob
    for p in args.paths:
        if not os.path.exists(p):
            print("跳过（不存在）:", p)
            continue
        # ★ 换行怎么处理，交给 git 判断（见 git_blob 的说明）。
        #   自己 replace(b"\r\n", b"\n") 会把二进制素材拆坏 —— 文件还在、
        #   体积只差十几字节、编译零报错，真机上只有一片黑。
        sha, data = git_blob(p)

        # 远端已有同 sha 的 blob 就不用传了
        try:
            req("GET", f"{API}/repos/{REPO}/git/blobs/{sha}", tok)
            print(f"blob 已存在 {p} ({sha[:10]}) {len(data)}B")
        except urllib.error.HTTPError:
            res = req("POST", f"{API}/repos/{REPO}/git/blobs", tok,
                      {"content": base64.b64encode(data).decode(), "encoding": "base64"})
            # 用 GitHub 返回的 sha，不信任自己算的
            sha = res["sha"]
            print(f"blob 已创建 {p} ({sha[:10]}) {len(data)}B")
        new_trees_items.append((p, sha))

    if not new_trees_items:
        print("没有要提交的文件")
        return

    # 3) 构造新 tree
    base_tree = req(
        "GET", f"{API}/repos/{REPO}/git/trees/{base_tree_sha}?recursive=1", tok)
    items = []
    seen = set()
    for ent in base_tree["tree"]:
        path = ent["path"]
        matched = None
        for p, sha in new_trees_items:
            if path == p or path == p.replace("\\", "/"):
                matched = sha
                seen.add(p)
                break
        if matched:
            items.append({"path": path, "mode": ent["mode"], "type": "blob", "sha": matched})
        else:
            items.append({"path": path, "mode": ent["mode"], "type": ent["type"], "sha": ent["sha"]})
    # 兜底：base tree 里没有的新文件
    for p, sha in new_trees_items:
        if p not in seen and p.replace("\\", "/") not in seen:
            items.append({"path": p.replace("\\", "/"), "mode": "100644",
                          "type": "blob", "sha": sha})

    new_tree = req("POST", f"{API}/repos/{REPO}/git/trees", tok,
                   {"base_tree": base_tree_sha, "tree": items})
    print(f"new tree: {new_tree['sha'][:10]}")

    # 4) 构造 commit
    new_commit = req("POST", f"{API}/repos/{REPO}/git/commits", tok, {
        "message": args.m,
        "tree": new_tree["sha"],
        "parents": [head_sha],
    })
    print(f"new commit: {new_commit['sha'][:10]}")

    # 5) 更新 master
    req("PATCH", f"{API}/repos/{REPO}/git/refs/heads/{BRANCH}", tok,
        {"sha": new_commit["sha"]})
    print(f"master -> {new_commit['sha'][:10]}  OK")


if __name__ == "__main__":
    main()
