#!/bin/bash
# 把 out/Still.ipa 弄到台子安装页。
#  1) 先试「台子自己拉」（一个请求；台子在云上下载）
#  2) 不行就分片并行上传，每片校验返回体里的 "ok": true
#  ★ 全过程录日志，结束时 POST 到台子的 /api/diag —— GitHub 的 job 日志我下不下来，
#    只能靠这条通道看台子到底回了什么。
set -uo pipefail

: "${PUSH_KEY:?没有 IOS_PUSH_KEY}"
: "${IPA:=out/Still.ipa}"
: "${BASE:=https://still-ui-design.app.workbuddy.host}"
: "${NAME:=Still.ipa}"
: "${PULL_URL:=https://github.com/xiaoli-2025315/Still-ios/releases/download/device/Still.ipa}"
: "${PARALLEL:=1}"
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
echo "本地期望版本: ${WANT:-未知}"

echo "=== 1) 试台子自己拉 ==="
pull=$(curl -sS --max-time 300 -X POST "$BASE/api/ios/pull?k=$PUSH_KEY&url=$PULL_URL" 2>&1)
echo "$pull" | head -c 300; echo

OK=0
if printf '%s' "$pull" | grep -q '"ok": true'; then
  n=0
  while [ "$n" -lt 5 ]; do
    n=$((n + 1))
    sleep 6
    got=$(curl -sS --max-time 20 "$BASE/api/ios/pkg" 2>/dev/null \
          | grep -o '"版本": *"[^"]*"' | head -1 | sed 's/.*"\(.*\)"/\1/')
    echo "  等拉取 $n: 台子=$got"
    if [ -n "$WANT" ] && [ "$got" = "$WANT" ]; then OK=1; break; fi
  done
else
  echo "(拉不起来)"
fi

if [ "$OK" = "1" ]; then
  echo "=== 台子自己拉成功（版本已对上）==="
  exit 0
fi
echo "=== 2) 分片并行上传 ==="

SIZE=$(wc -c < "$IPA" | tr -d ' ')
echo "包大小 $SIZE 字节 ($((SIZE / 1048576)) MB)，并行 $PARALLEL"
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
    echo "  片 $idx off=$off http=$code 失败: $(printf '%s' "$resp" | head -c 200)"
    return 1
  fi
  echo "  片 $idx off=$off http=$code ok"
  return 0
}

FAIL=0; idx=0
for f in .chunks/p*; do
  upload_one "$idx" "$f" &
  idx=$((idx + 1))
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PARALLEL" ]; do sleep 0.4; done
done
wait || FAIL=1
if [ "$FAIL" -ne 0 ]; then
  echo "=== 有分片失败，不 adopt ==="
  exit 1
fi

echo "=== adopt ==="
aresp=$(curl -sS --max-time 180 -X POST "$BASE/api/ios/adopt?k=$PUSH_KEY&name=$NAME" 2>&1)
echo "$aresp" | head -c 400; echo
printf '%s' "$aresp" | grep -q '"ok": true' || { echo "=== adopt 失败 ==="; exit 1; }
echo "=== 台子已挂上 ==="
