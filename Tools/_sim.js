// 复刻 PetEngine 的核心逻辑跑模拟
// 目的：在没有真机的情况下，验证「它会不会真的自己动、动得频不频繁、跨页多不多」
// 用的是和 Swift 里完全一样的算法（splitmix64 + FNV-1a + 同一套概率），
// 所以这里的数字就是真机上会出现的数字。

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
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

// ── 常量（对齐 StillConfig.swift）──────────────────────
const STAY_MIN = 1.0, STAY_MAX = 3.4;
const SAME_PAGE = 0.70, ISLAND = 0.14, HOME_PULL = 0.06;

const ROOMS = [
  ['still', 0], ['clock', 0], ['weather', 0], ['photo', 0], ['notes', 0],
  ['music', 1], ['podcast', 1], ['cal', 1], ['remind', 1], ['health', 1], ['maps', 1],
  ['album', 2], ['battery', 2], ['short', 2], ['world', 2], ['timer', 2],
];
const PAGE = Object.fromEntries(ROOMS);

function buildSchedule(span = 600, back = 26) {
  const rnd = splitmix64(fnv('still-ios-widgets'));
  const bool = p => rnd() < p;
  const list = [];
  let t = -back, cur = 'weather';
  while (t < span) {
    const dur = STAY_MIN + rnd() * (STAY_MAX - STAY_MIN);
    let target;
    if (PAGE[cur] !== PAGE['still'] && bool(HOME_PULL)) {
      target = 'still';
    } else {
      const same = ROOMS.filter(([id, p]) => p === PAGE[cur] && id !== cur);
      const any = ROOMS.filter(([id]) => id !== cur);
      const pool = (bool(SAME_PAGE) && same.length) ? same : any;
      target = pool[Math.floor(rnd() * pool.length)][0];
    }
    list.push({ t0: t, t1: t + dur, at: cur, to: target, island: bool(ISLAND) });
    t += dur; cur = target;
  }
  return list;
}

// ── 动作链（对齐 PetEngine.pickAct）───────────────────
const ACT_NAME = { sleep: '睡觉', groom: '舔毛', stretch: '伸懒腰', hunt: '扑着玩', sit: '坐着发呆', look: '抬头张望' };
const ACT_SEC = { sleep: [9.0, 16], groom: [4.2, 7.2], stretch: [2.1, 2.8], hunt: [2.5, 3.1], sit: [4.0, 8.0], look: [2.5, 4.1] };

function pickAct(prev, r) {
  switch (prev) {
    case 'sleep':   return r < 0.42 ? 'stretch' : (r < 0.78 ? 'groom' : 'sit');
    case 'hunt':    return r < 0.56 ? 'sit' : 'groom';
    case 'stretch': return r < 0.44 ? 'groom' : (r < 0.70 ? 'hunt' : 'sit');
    default:
      return r < 0.30 ? 'sleep' : r < 0.48 ? 'groom' : r < 0.60 ? 'look'
           : r < 0.67 ? 'stretch' : r < 0.76 ? 'hunt' : 'sit';
  }
}

// ═══════════════════════════════════════════════════
// 1. 行程表统计
const S = buildSchedule();
const win = S.filter(s => s.t1 > 0 && s.t0 < 72);   // 未来 3 天
let cross = 0, island = 0;
const durSum = win.reduce((a, s) => {
  if (PAGE[s.at] !== PAGE[s.to]) cross++;
  if (s.island) island++;
  return a + (s.t1 - s.t0);
}, 0);
const avgStay = durSum / win.length;

console.log('══ 行程表（未来 3 天）══');
console.log('  挪窝次数        ' + win.length);
console.log('  平均停留        ' + avgStay.toFixed(2) + ' 小时');
console.log('  跨页比例        ' + (cross / win.length * 100).toFixed(1) + '%   ← 目标是「少数」，穿梭该发生在同一屏里');
console.log('  去灵动岛        ' + (island / win.length * 100).toFixed(1) + '%');
console.log('  一天挪窝        ' + (24 / avgStay).toFixed(1) + ' 次');

// 2. 每个组件被光顾的次数
const hit = {};
win.forEach(s => { hit[s.at] = (hit[s.at] || 0) + 1; });
const top = Object.entries(hit).sort((a, b) => b[1] - a[1]);
console.log('\n══ 3 天里各组件被待过的次数 ══');
console.log('  最多: ' + top.slice(0, 4).map(([k, v]) => k + '×' + v).join('  '));
console.log('  最少: ' + top.slice(-4).map(([k, v]) => k + '×' + v).join('  '));
console.log('  3 天里没去过的: ' + (ROOMS.filter(([id]) => !hit[id]).map(x => x[0]).join(',') || '无 —— 16 个都去过了'));
{
  const w7 = S.filter(s => s.t1 > 0 && s.t0 < 168);
  const h7 = {}; w7.forEach(s => { h7[s.at] = (h7[s.at] || 0) + 1; });
  const miss7 = ROOMS.filter(([id]) => !h7[id]).map(x => x[0]);
  const vals = Object.values(h7);
  console.log('  7 天(' + w7.length + ' 次挪窝) 最少被去的: ' + Object.entries(h7).sort((a,b)=>a[1]-b[1]).slice(0,4).map(([k,v])=>k+'×'+v).join('  '));
  console.log('  7 天里没去过的: ' + (miss7.length ? miss7.join(',') : '无 —— 16 个都去过'));
}

// 3. 动作分布（模拟 4000 次动作）
const r2 = splitmix64(99);
let act = 'look', counts = {}, secTotal = 0;
for (let i = 0; i < 4000; i++) {
  act = pickAct(act, r2());
  counts[act] = (counts[act] || 0) + 1;
  const [lo, hi] = ACT_SEC[act];
  secTotal += lo + r2() * (hi - lo);
}
console.log('\n══ 动作分布（4000 次采样）══');
Object.entries(counts).sort((a, b) => b[1] - a[1]).forEach(([k, v]) => {
  const pct = v / 4000 * 100;
  console.log('  ' + ACT_NAME[k].padEnd(5, '　') + ' ' + pct.toFixed(1).padStart(5) + '%  ' + '█'.repeat(Math.round(pct / 2)));
});
console.log('  平均每个动作 ' + (secTotal / 4000).toFixed(1) + ' 秒');
console.log('  一次停留(' + avgStay.toFixed(1) + 'h)里约做 ' + Math.round(avgStay * 3600 / (secTotal / 4000)) + ' 个动作');

// 4. 撞见概率
const movesPerDay = 24 / avgStay;
const walkSecPerDay = movesPerDay * 4.5;
const glances = 80;
const p = 1 - Math.pow(1 - walkSecPerDay / 86400, glances);
console.log('\n══ 撞见概率 ══');
console.log('  一天累计走路 ' + walkSecPerDay.toFixed(0) + ' 秒（' + movesPerDay.toFixed(1) + ' 次 × 4.5 秒）');
console.log('  假设一天瞥 ' + glances + ' 次手机');
console.log('  → 单日撞见概率 ' + (p * 100).toFixed(1) + '%，约 ' + (1 / p).toFixed(0) + ' 天撞见一次它在走');

// 5. 演示档节奏
console.log('\n══ 演示倍速下的实际等待 ══');
[1, 60, 300, 600].forEach(sp => {
  const sec = avgStay * 3600 / sp;
  console.log('  ' + String(sp).padStart(3) + '×  → 平均 ' + (sec < 90 ? sec.toFixed(0) + ' 秒' : (sec / 60).toFixed(1) + ' 分钟') + ' 挪一次窝（走路本身 ' + (4.5) + ' 秒不压缩）');
});
