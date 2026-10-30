#!/bin/bash
# 把 out/Still.ipa 弄到台子安装页。两条路，先试快的：
#
#  ① 台子自己拉（A 方案）：只发一个请求，台子在云上下载，秒级。
#     前提：台子能访问 GitHub（部署 0030 之后就能试）。
#  ② 分片并行上传（兜底）：4 路并行 + 每片校验 "ok": true。
#     v99~v104 那几次失败就是顺序传 + 不校验造成的。
set -uo pipefail

: "${PUSH_KEY:?没有 IOS_PUSH_KEY}"
: "${IPA:=out/Still.ipa}"
: "${BASE:=https://still-ui-design.app.workbuddy.host}"
: "${NAME:=Still.ipa}"
: "${PULL_URL:=https://github.com/xiaoli-2025315/Still-ios/releases/download/device/Still.ipa}"
: "${PARALLEL:=4}"
: "${CHUNK:=2097152}"

[ -f "$IPA" ] || { echo "找不到 $IPA"; exit 1; }

# ---------- ① 先试「台子自己拉」 ----------
echo "═══ ① 试台子自己拉（$PULL_URL）═══"
pull=$(curl -sS --max-time 300 -X POST \
       "$BASE/api/ios/pull?k=$PUSH_KEY&url=$(printf '%s' "$PULL_URL" | sed 's|:|%3A|g; s|/|%2F|g')" 2>&1)
echo "$pull" | head -c 400
echo
if printf '%s' "$pull" | grep -q '"ok": true'; then
  echo "═══ 台子自己拉成功，收工 ═══"
  exit 0
fi
echo "（台子拉不动，走 ② 分片并行）"

# ---------- ② 分片并行 ----------
SIZE=$(wc -c < "$IPA" | tr -d ' ')
echo "包大小 $SIZE 字节（$((SIZE / 1048576)) MB），并行 $PARALLEL"
rm -rf .chunks && mkdir -p .chunks
split -b "$CHUNK" "$IPA" .chunks/p

upload_one() {
  idx="$1"; f="$2"
  off=$((idx * CHUNK))
  resp=$(curl -sS --max-time 180 --retry 4 --retry-all-errors --retry-delay 2 \
         -w '\nHTTP:%{http_code}' \
         -X POST --data-binary @"$f" -H "Content-Type: application/octet-stream" \
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
