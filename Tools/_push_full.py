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
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True,
    ).stdout
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


def local_blob_sha(path: str) -> str:
    """用 git 的算法算本地文件的 blob sha（与远端 blob 同算法）。"""
    with open(path, "rb") as f:
        data = f.read()
    if os.name == "nt":
        data = data.replace(b"\r\n", b"\n")
    blob = b"blob " + str(len(data)).encode() + b"\0" + data
    return hashlib.sha1(blob).hexdigest()


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
        # ★ 必须先规范化换行再算 sha、再上传。
        #   否则 Windows 的 CRLF 会让「本地算出的 sha」和「GitHub 存下的 blob sha」对不上，
        #   构造 tree 时报 "is not a valid blob"。
        with open(p, "rb") as f:
            raw = f.read()
        norm = raw.replace(b"\r\n", b"\n") if os.name == "nt" else raw
        sha = hashlib.sha1(
            b"blob " + str(len(norm)).encode() + b"\0" + norm).hexdigest()

        # 远端已有同 sha 的 blob 就不用传了
        try:
            req("GET", f"{API}/repos/{REPO}/git/blobs/{sha}", tok)
            print(f"blob 已存在 {p} ({sha[:10]})")
        except urllib.error.HTTPError:
            res = req("POST", f"{API}/repos/{REPO}/git/blobs", tok,
                      {"content": base64.b64encode(norm).decode(), "encoding": "base64"})
            # 用 GitHub 返回的 sha，不信任自己算的
            sha = res["sha"]
            print(f"blob 已创建 {p} ({sha[:10]})")
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
