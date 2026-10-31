#!/bin/bash
# 把 out/Still.ipa 弄到台子安装页，并且**验完才算数**。
#
# ★ 2026-10-31 为什么重写：
#   v1.112.0 挂上去的包是坏的 —— 前 8.86MB 全是 0，30 个文件里 26 个读不出来
#   （主程序 Still、CodeResources、大半视频都在空字节区）。
#   原因：脚本先发了「台子自己拉」（后台在下载），没等结束就分片上传，
#         两条路写同一个暂存文件，前面的分片被后面截掉；
#         而 adopt 只读版本号不验 zip，坏包就被当成好包挂上。
#
#   现在：
#     ① 只走一条路（分片顺序上传），彻底不碰 pull
#     ② adopt 之后把线上包下回来验 大小 / PK 头 / unzip -t，不过就红
#     ③ 再验一次台子回的版本号
set -uo pipefail

: "${PUSH_KEY:?没有 IOS_PUSH_KEY}"
: "${IPA:=out/Still.ipa}"
: "${BASE:=https://still-ui-design.app.workbuddy.host}"
: "${NAME:=Still.ipa}"
: "${CHUNK:=2097152}"

LOG=$(mktemp)
exec > >(tee -a "$LOG") 2>&1

report() {
  python3 - "$LOG" "$BASE" <<'PY' || true
import json, sys, urllib.request
log_path, base = sys.argv[1], sys.argv[2]
try:
    text = open(log_path, encoding="utf-8", errors="replace").read()[-3500:]
except Exception:
    text = ""
body = json.dumps({"来源": "ci_sync", "日志": text}, ensure_ascii=False).encode()
req = urllib.request.Request(base + "/api/diag", data=body,
                             headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=20).read()
except Exception:
    pass
PY
}
trap 'rc=$?; report; exit $rc' EXIT

[ -f "$IPA" ] || { echo "找不到 $IPA"; exit 1; }

WANT=$(grep -m1 'MARKETING_VERSION' project.yml 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')
SIZE=$(wc -c < "$IPA" | tr -d ' ')
head8=$(head -c 4 "$IPA" | od -An -tx1 | tr -d ' \n')
echo "本地包: 版本=${WANT:-未知} 大小=$SIZE 头=$head8"
if [ "$head8" != "504b0304" ]; then
  echo "本地包不是 zip，不传"
  exit 1
fi

echo "=== 1) 分片顺序上传（唯一写路径，不再并行、不再 pull）==="
rm -rf .chunks && mkdir -p .chunks
split -b "$CHUNK" "$IPA" .chunks/p
idx=0
for f in .chunks/p*; do
  off=$((idx * CHUNK))
  resp=$(curl -sS --max-time 180 --retry 4 --retry-all-errors --retry-delay 2 \
         -w '\nHTTP:%{http_code}' -X POST --data-binary @"$f" \
         -H "Content-Type: application/octet-stream" \
         "$BASE/api/ios/up?k=$PUSH_KEY&name=$NAME&off=$off&size=$SIZE" 2>&1)
  code=$(printf '%s' "$resp" | tail -1 | sed 's/HTTP://')
  if ! printf '%s' "$resp" | grep -q '"ok": true'; then
    echo "  片 $idx off=$off http=$code 失败: $(printf '%s' "$resp" | head -c 200)"
    exit 1
  fi
  echo "  片 $idx off=$off http=$code ok"
  idx=$((idx + 1))
done

echo "=== 2) adopt ==="
aresp=$(curl -sS --max-time 180 -X POST "$BASE/api/ios/adopt?k=$PUSH_KEY&name=$NAME" 2>&1)
echo "$aresp" | head -c 300; echo
printf '%s' "$aresp" | grep -q '"ok": true' || { echo "adopt 失败"; exit 1; }

echo "=== 3) 把线上包下回来验（这才是他真会装到的那个）==="
sleep 2
curl -sS --max-time 300 -o .verify.ipa "$BASE/api/ios/pkg.ipa" 2>/dev/null
gsize=$(wc -c < .verify.ipa | tr -d ' ')
ghead=$(head -c 4 .verify.ipa | od -An -tx1 | tr -d ' \n')
echo "  线上: 大小=$gsize (本地 $SIZE) 头=$ghead"
[ "$gsize" = "$SIZE" ] || { echo "大小不一致"; exit 1; }
[ "$ghead" = "504b0304" ] || { echo "不是 zip 头"; exit 1; }
if command -v unzip >/dev/null 2>&1; then
  if unzip -t .verify.ipa >/dev/null 2>&1; then
    echo "  unzip -t 通过"
  else
    echo "  unzip -t 失败：包解不开"
    unzip -t .verify.ipa 2>&1 | tail -5
    exit 1
  fi
fi

echo "=== 4) 版本号 ==="
gotver=$(curl -sS --max-time 20 "$BASE/api/ios/pkg" | grep -o '"版本": *"[^"]*"' | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "  台子版本=$gotver 期望=${WANT:-?}"
[ -z "$WANT" ] || [ "$gotver" = "$WANT" ] || { echo "版本不一致"; exit 1; }

echo "=== 台子已挂上，且验过是完整包 ==="
