#!/bin/bash
# 把 out/Still.ipa 传到台子安装页（分片 + 并行 + 每片校验返回体）
#
# ★ 2026-10-30 为什么重写：
#   原来顺序传 6 片 × 2MB，链路一慢每片要 5 分钟 —— 整个 job 挂 30 分钟还传不完，
#   而且 curl 收到 403/400 也算"成功"，脚本报绿、台子其实没变（v99~v104 都栽在这）。
#   现在：① 4 路并行（台子按 off 写暂存文件，不同偏移互不干扰）
#         ② 每片检查返回体里的 "ok": true，不满足就整体失败
#         ③ adopt 也检查返回体，并把"收到哪一版"打出来
set -uo pipefail

: "${PUSH_KEY:?没有 IOS_PUSH_KEY}"
: "${IPA:=out/Still.ipa}"
: "${BASE:=https://still-ui-design.app.workbuddy.host}"
: "${NAME:=Still.ipa}"
: "${PARALLEL:=4}"
: "${CHUNK:=2097152}"

[ -f "$IPA" ] || { echo "找不到 $IPA"; exit 1; }
SIZE=$(wc -c < "$IPA" | tr -d ' ')
echo "包大小 $SIZE 字节（$((SIZE / 1048576)) MB），分片 ${CHUNK}，并行 ${PARALLEL}"

rm -rf .chunks && mkdir -p .chunks
split -b "$CHUNK" "$IPA" .chunks/p
COUNT=$(ls .chunks/p* | wc -l | tr -d ' ')
echo "共 $COUNT 片"

upload_one() {
  idx="$1"; f="$2"
  off=$((idx * CHUNK))
  resp=$(curl -sS --max-time 180 --retry 4 --retry-all-errors --retry-delay 2 \
         -w '\nHTTP:%{http_code}' \
         -X POST --data-binary @"$f" -H "Content-Type: application/octet-stream" \
         "$BASE/api/ios/up?k=$PUSH_KEY&name=$NAME&off=$off&size=$SIZE" 2>&1)
  code=$(printf '%s' "$resp" | tail -1 | sed 's/HTTP://')
  ok=$(printf '%s' "$resp" | grep -c '"ok": true')
  echo "  片 $idx off=$off http=$code ok=$ok"
  if [ "$ok" -lt 1 ]; then
    echo "  片 $idx 失败，返回：$(printf '%s' "$resp" | head -c 300)"
    return 1
  fi
  return 0
}

fail=0
idx=0
for f in .chunks/p*; do
  upload_one "$idx" "$f" &
  idx=$((idx + 1))
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PARALLEL" ]; do sleep 0.4; done
done
wait || fail=1

if [ "$fail" -ne 0 ]; then
  echo "═══ 有分片没传成功，不 adopt ═══"
  exit 1
fi

echo "═══ 全部分片完成，adopt ═══"
aresp=$(curl -sS --max-time 180 -X POST "$BASE/api/ios/adopt?k=$PUSH_KEY&name=$NAME" 2>&1)
echo "$aresp" | head -c 600
echo
if ! printf '%s' "$aresp" | grep -q '"ok": true'; then
  echo "═══ adopt 失败 ═══"
  exit 1
fi
echo "═══ 台子已挂上 ═══"
