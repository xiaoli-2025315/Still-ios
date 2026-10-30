#!/bin/bash
# 把 out/Still.ipa 弄到台子安装页。
#  ① 先试「台子自己拉」（一个请求，台子在云上下载）
#  ② 不行就分片并行上传，每片校验返回体里的 "ok": true
#  ★ 全过程把输出录下来，失败时 POST 到台子的 /api/diag —— 这样我不用 GitHub 登录
#    也能看到台子到底回了什么（CI 日志我下不下来）。
set -uo pipefail

: "${PUSH_KEY:?没有 IOS_PUSH_KEY}"
: "${IPA:=out/Still.ipa}"
: "${BASE:=https://still-ui-design.app.workbuddy.host}"
: "${NAME:=Still.ipa}"
: "${PULL_URL:=https://github.com/xiaoli-2025315/Still-ios/releases/download/device/Still.ipa}"
: "${PARALLEL:=4}"
: "${CHUNK:=2097152}"

LOG=$(mktemp)
exec > >(tee -a "$LOG") 2>&1

report() {
  # 把这次同步的经过发到台子（/api/diag 是公开只收不判的）
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
    print("（已把本次同步日志发到台子 /api/diag）")
except Exception as e:
    print("（发日志失败：%s）" % e)
PY
}

trap 'rc=$?; report; exit $rc' EXIT

[ -f "$IPA" ] || { echo "找不到 $IPA"; exit 1; }

echo "═══ ① 试台子自己拉 ═══"
want_ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
           "$(dirname "$IPA")/Still.xcarchive/Products/Applications/Still.app/Info.plist" 2>/dev/null || echo "")
echo "本地包版本：$want_ver"

pull=$(curl -sS --max-time 300 -X POST "$BASE/api/ios/pull?k=$PUSH_KEY&url=$PULL_URL" 2>&1)
echo "$pull" | head -c 400; echo

ok=0
if printf '%s' "$pull" | grep -q '"ok": true'; then
  for i in $(seq 1 20); do
    sleep 6
    got=$(curl -sS --max-time 20 "$BASE/api/ios/pkg" 2>/dev/null \
          | grep -o '"版本": *"[^"]*"' | head -1 | sed 's/.*"\(.*\)"/\1/')
    prog=$(curl -sS --max-time 20 "$BASE/api/ios/pull?k=$PUSH_KEY" 2>/dev/null | tr -d '\n ')
    echo "  等拉取 $i：台子版本=$got 进度=$(printf '%s' "$prog" | head -c 100)"
    if [ -n "$want_ver" ] && [ "$got" = "$want_ver" ]; then ok=1; break; fi
  done
else
  echo "（拉不起来）"
fi

if [ "$ok" = "1" ]; then
  echo "═══ 台子自己拉成功（版本已对上）═══"
  exit 0
fi
echo "（走 ② 分片并行上传）"

SIZE=$(wc -c < "$IPA" | tr -d ' ')
echo "包大小 $SIZE 字节（$((SIZE / 1048576)) MB），并行 $PARALLEL"
rm -rf .chunks && mkdir -p .chunks
split -b "$CHUNK" "$IPA" .chunks/p

upload_one() {
  idx="$1"; f="$2"
  off=$((idx * CHUNK))
  resp=$(curl -sS --max-time 180 --retry 4 --retry-all-errors --retry-delay 2 \
         -w '\nHTTP:%{http_code}' -X POST --data-binary @"$f" \
         -H "Content-Type: application/octet-stream" \
         "$BASE/api/ios/up?k=$PUSH_KEY&name=$NAME&off=$off&size=$SIZE" 2>&1)
  code=$(printf '%s' "$resp" | tail -1 | sed 's/HTTP://')
  if ! printf '%s' "$resp" | grep -q '"ok": true'; then
    echo "  片 $idx off=$off http=$code 失败：$(printf '%s' "$resp" | head -c 240)"
    return 1
  fi
  echo "  片 $idx off=$off http=$code ok"
  return 0
}

fail=0; idx=0
for f in .chunks/p*; do
  upload_one "$idx" "$f" &
  idx=$((idx + 1))
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PARALLEL" ]; do sleep 0.4; done
done
wait || fail=1
[ "$fail" -ne 0 ] && { echo "═══ 有分片失败，不 adopt ═══"; exit 1; }

echo "═══ adopt ═══"
aresp=$(curl -sS --max-time 180 -X POST "$BASE/api/ios/adopt?k=$PUSH_KEY&name=$NAME" 2>&1)
echo "$aresp" | head -c 500; echo
printf '%s' "$aresp" | grep -q '"ok": true' || { echo "═══ adopt 失败 ═══"; exit 1; }
echo "═══ 台子已挂上 ═══"
