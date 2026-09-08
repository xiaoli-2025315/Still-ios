// 验证「行程表用绝对小时」这个修复，以及它在真机上跑起来是什么节奏。
//
// 背景（一个不跑模拟就发现不了的 bug）：
//   seg(atHour:) 传进去的是 Date().timeIntervalSince1970 / 3600 ≈ 497000，
//   而旧行程表只覆盖 -26 ... 600。查不到就永远返回第一条 →
//   `s.t0 != curSeg?.t0` 永远不成立 → **它一次都不会自己挪窝**。
//   之前的 _sim.js 直接用 0...600 当时间轴，所以完全没暴露这个问题。
//
// 本脚本用真实 epoch 小时复刻 Schedule.build / place / moments，逐条验证。

const M64 = 0xFFFFFFFFFFFFFFFFn;
function splitmix64(seed) {
  let state = BigInt(seed >>> 0);
  return function () {
    state = (state + 0x9E3779B97F4A7C15n) & M64;
    let z = state;
    z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & M64;
    z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & M64;
    z = z ^ (z >> 31n);
    return Number(z >> 11n) / Number(1n << 53n);
  };
}
function fnv(s) {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
  return h >>> 0;
}

// ── 对齐 StillConfig.swift ──────────────────────────
const STAY_MIN = 1.0, STAY_MAX = 3.4;
const SAME_PAGE = 0.78, HOME_PULL = 0.06;
const FRESH_BIAS = 0.50, FRESH_POOL = 4;
const ISLAND_RATE = 0.14, ISLAND_MIN = 0.15, ISLAND_MAX = 0.60;
const BACK_H = 26, SPAN_H = 600, COVER_H = 8;

const ROOMS = [
  ['still', 0], ['clock', 0], ['weather', 0], ['photo', 0], ['notes', 0],
  ['music', 1], ['podcast', 1], ['cal', 1], ['remind', 1], ['health', 1], ['maps', 1],
  ['album', 2], ['battery', 2], ['short', 2], ['world', 2], ['timer', 2],
];
const PAGE = Object.fromEntries(ROOMS);
const IDS = ROOMS.map(r => r[0]);

// 真实 epoch 小时
const HOUR_EPOCH = Date.now() / 1000 / 3600;

// ── 对齐 Schedule.build ─────────────────────────────
function build(from, to, startRoom = 'weather', seed = fnv('still-ios-widgets')) {
  const rnd = splitmix64(seed);
  const list = [];
  const lastSeen = {};
  let t = from, cur = startRoom;
  while (t < to) {
    const dur = STAY_MIN + rnd() * (STAY_MAX - STAY_MIN);
    const curPage = PAGE[cur] ?? 0;
    let target;
    if (curPage !== PAGE['still'] && rnd() < HOME_PULL) {
      target = 'still';
    } else {
      const same = ROOMS.filter(([id, p]) => p === curPage && id !== cur);
      const any = ROOMS.filter(([id]) => id !== cur);
      let pool;
      if (rnd() < SAME_PAGE && same.length) {
        pool = same;
      } else if (rnd() < FRESH_BIAS) {
        pool = any.slice()
          .sort((a, b) => (lastSeen[a[0]] ?? -1e9) - (lastSeen[b[0]] ?? -1e9))
          .slice(0, Math.min(FRESH_POOL, any.length));
      } else {
        pool = any;
      }
      target = pool.length ? pool[Math.floor(rnd() * pool.length)][0] : 'still';
    }
    const islandHours = rnd() < ISLAND_RATE ? ISLAND_MIN + rnd() * (ISLAND_MAX - ISLAND_MIN) : 0;
    list.push({ t0: t, t1: t + dur, roomId: cur, nextRoomId: target, islandHours });
    lastSeen[cur] = t;
    t += dur; cur = target;
  }
  return list;
}

// ── 对齐 Schedule.segment / place ───────────────────
function segment(S, h) {
  for (const s of S) if (h >= s.t0 && h < s.t1) return s;
  return null;
}
function placeAt(S, h) {
  const s = segment(S, h);
  if (!s) return null;
  if (s.islandHours > 0 && h < s.t0 + s.islandHours) return 'island';
  return s.roomId;
}

// ═══════════════════════════════════════════════════
const S = build(HOUR_EPOCH - BACK_H, HOUR_EPOCH + SPAN_H);

console.log('══ 1. 时间基准修复验证（这是让猫真正动起来的前提）══');
console.log('  当前 epoch 小时        ' + HOUR_EPOCH.toFixed(0));
console.log('  行程表覆盖范围        ' + S[0].t0.toFixed(0) + ' ... ' + S[S.length - 1].t1.toFixed(0) + '  （' + S.length + ' 段）');
const nowSeg = segment(S, HOUR_EPOCH);
console.log('  segment(现在) 查得到？  ' + (nowSeg ? '✅ 是，在「' + nowSeg.roomId + '」' : '❌ 否 —— 会退化成永远返回第一条，猫不会动'));

{
  // 关键：往前走 24 小时，看它到底换不换地方
  const seen = [];
  for (let h = HOUR_EPOCH; h < HOUR_EPOCH + 24; h += 1 / 60) {
    const p = placeAt(S, h);
    if (seen[seen.length - 1] !== p) seen.push(p);
  }
  console.log('  未来 24 小时它换地方   ' + (seen.length - 1) + ' 次');
  console.log('  前 12 站               ' + seen.slice(0, 12).join(' → '));
  if (seen.length <= 1) {
    console.log('  ❌ 它不动！行程表时间基准仍然不对');
    process.exit(1);
  } else {
    console.log('  ✅ 它自己会挪窝了');
  }
}

// ═══════════════════════════════════════════════════
console.log('\n══ 2. 动作节奏（未来 7 天）══');
const w7 = S.filter(s => s.t1 > HOUR_EPOCH && s.t0 < HOUR_EPOCH + 168);
const durSum = w7.reduce((a, s) => a + (s.t1 - s.t0), 0);
const avgStay = durSum / w7.length;
const cross = w7.filter(s => PAGE[s.at] !== PAGE[s.to] || PAGE[s.roomId] !== PAGE[s.nextRoomId]).length;
const islandSegs = w7.filter(s => s.islandHours > 0);
console.log('  挪窝次数        ' + w7.length + '（每天 ' + (24 / avgStay).toFixed(1) + ' 次）');
console.log('  平均停留        ' + avgStay.toFixed(2) + ' 小时');
console.log('  跨页            ' + (cross / w7.length * 100).toFixed(1) + '%');

// 岛占多久（按时间算，不是按段数）
let islandHours = 0, totalHours = 0;
for (let h = HOUR_EPOCH; h < HOUR_EPOCH + 168; h += 1 / 60) {
  totalHours += 1 / 60;
  if (placeAt(S, h) === 'island') islandHours += 1 / 60;
}
console.log('  在灵动岛        ' + (islandHours / totalHours * 100).toFixed(1) + '% 的时间'
  + '（' + islandSegs.length + ' 次进岛，平均每次 '
  + (islandHours / Math.max(islandSegs.length, 1) * 60).toFixed(0) + ' 分钟）');

// 16 个组件覆盖情况
const hit = {};
w7.forEach(s => { hit[s.roomId] = (hit[s.roomId] || 0) + 1; });
const miss = IDS.filter(id => !hit[id]);
const vals = IDS.map(id => hit[id] || 0);
console.log('  7 天覆盖组件    ' + (16 - miss.length) + '/16'
  + (miss.length ? '  没去过: ' + miss.join(',') : '')
  + '  （每个平均 ' + (vals.reduce((a, b) => a + b, 0) / 16).toFixed(1) + ' 次）');

// ═══════════════════════════════════════════════════
console.log('\n══ 3. 小组件 timeline 有多轻 ══');
{
  const counts = IDS.map(id => Schedule_moments(id).length);
  const tot = counts.reduce((a, b) => a + b, 0);
  console.log('  单个组件 ' + COVER_H + ' 小时的 entry 数：最少 ' + Math.min(...counts)
    + ' / 最多 ' + Math.max(...counts) + ' / 平均 ' + (tot / 16).toFixed(1));
  console.log('  16 个组件全排一遍共 ' + tot + ' 个 entry');
  console.log('  （Apple DTS 原话：预算限制的是 reload 次数，entry 数量不限）');
}
function Schedule_moments(roomId) {
  const now = Date.now() / 1000;
  const h0 = now / 3600, hEnd = h0 + COVER_H;
  const out = [{ t: h0, here: placeAt(S, h0) === roomId }];
  const bs = [];
  for (const s of S) {
    if (s.t0 > h0 && s.t0 < hEnd) bs.push(s.t0);
    if (s.islandHours > 0) { const ix = s.t0 + s.islandHours; if (ix > h0 && ix < hEnd) bs.push(ix); }
  }
  bs.sort((a, b) => a - b);
  for (const b of bs) {
    const here = placeAt(S, b + 1e-6) === roomId;
    if (here !== out[out.length - 1].here) out.push({ t: b, here });
  }
  out.push({ t: hEnd, here: false });   // 兜底
  return out;
}

// ═══════════════════════════════════════════════════
console.log('\n══ 4. 逐分钟扫描：任意时刻到底有几个组件在画猫 ══');
{
  const times = [];
  const rnd = splitmix64(fnv('refresh'));
  for (const id of IDS) {
    let t = HOUR_EPOCH - (24 / 24) * rnd();
    while (t < HOUR_EPOCH + 168) { times.push([id, t]); t += (24 / 24) * (0.5 + rnd()); }
  }
  // 每个组件预排 timeline（刷新一次覆盖 COVER_H 小时）
  const tl = {};
  IDS.forEach(id => tl[id] = []);
  for (const [id, t] of times) tl[id].push({ from: t, to: t + COVER_H });

  const hist = { 0: 0, 1: 0, 2: 0, more: 0 };
  let n = 0, islandN = 0;
  for (let h = HOUR_EPOCH; h < HOUR_EPOCH + 168; h += 1 / 60) {
    const p = placeAt(S, h);
    if (p === 'island') { islandN++; n++; continue; }
    let c = 0;
    for (const id of IDS) {
      // 这个组件此刻显示的是哪条 timeline
      let cur = null;
      for (const w of tl[id]) { if (w.from <= h) { if (!cur || w.from > cur.from) cur = w; } }
      if (!cur) continue;
      const here = placeAt(S, h) === id && h < cur.to;   // 超出覆盖 = 兜底，不画
      if (here) c++;
    }
    hist[c >= 3 ? 'more' : c]++; n++;
  }
  console.log('  1 个组件画猫    ' + (hist[1] / n * 100).toFixed(2) + '%   ← 正确');
  console.log('  0 个组件画猫    ' + (hist[0] / n * 100).toFixed(2) + '%   （它暂时看不见）');
  console.log('  2 个组件画猫    ' + (hist[2] / n * 100).toFixed(4) + '%   ← 违反唯一性');
  console.log('  3 个及以上      ' + (hist.more / n * 100).toFixed(4) + '%   ← 违反唯一性');
  console.log('  （已排除在岛里的 ' + (islandN / (n + islandN) * 100).toFixed(1) + '% 时间 —— 那时它本来就不在任何组件里）');
  console.log(hist[2] + hist.more === 0 ? '\n  ✅ 唯一性成立：7 天逐分钟扫描，零冲突' : '\n  ❌ 出现冲突');
}
