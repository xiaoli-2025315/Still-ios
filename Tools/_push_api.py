#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 GitHub Contents API 直接提交文件 —— git push 走不通时的备用通道。

用法：
  python Tools/_push_api.py project.yml Sources/Widget/StillWidget.swift

原理：git 的 https 通道在代理下经常握手失败/502，但 Python 的 urllib 走得通。
所以：从 git credential 里取出令牌 → 调 Contents API 逐个文件 PUT。
每个文件必须先 GET 拿当前 blob sha，否则会 409。

限制：一次提交的多个文件在远端会变成**多个 commit**（API 是逐文件的），
      对 CI 来说没区别（只关心最终 HEAD 的内容）。
"""
import base64
import json
import subprocess
import sys
import time
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
    raise SystemExit("拿不到 GitHub 令牌，先确认 git credential 里有")


def req(method: str, url: str, tok: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", f"Bearer {tok}")
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "still-push")
    if data:
        r.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.load(resp)


def main():
    paths = sys.argv[1:]
    if not paths:
        raise SystemExit(__doc__)
    tok = token()
    for p in paths:
        if not os.path.exists(p):
            print("跳过（不存在）:", p)
            continue
        url = f"{API}/repos/{REPO}/contents/{p}?ref={BRANCH}"
        try:
            cur = req("GET", url, tok)
            sha = cur["sha"]
        except urllib.error.HTTPError as e:
            if e.code == 404:
                sha = None
            else:
                print("GET 失败", p, e)
                continue
        with open(p, "rb") as f:
            content = base64.b64encode(f.read()).decode()
        body = {
            "message": f"chore: {p}（API 通道提交）",
            "content": content,
            "branch": BRANCH,
        }
        if sha:
            body["sha"] = sha
        try:
            res = req("PUT", f"{API}/repos/{REPO}/contents/{p}", tok, body)
            print("OK", p, "->", res["commit"]["sha"][:7])
        except urllib.error.HTTPError as e:
            print("PUT 失败", p, e.code, e.read()[:200])
        time.sleep(1)


import os  # noqa: E402

if __name__ == "__main__":
    main()
