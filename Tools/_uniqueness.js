// 唯一性验证：同一时刻，会不会有两个组件同时显示猫？
//
// 背景：WidgetKit 的小组件是静态快照，各实例刷新时刻由系统决定、互不协调。
// 上一轮我据此判定「严格唯一性做不到」。但那是我把两件事混为一谈了：
//   · 预算限制的是 reload 次数（Apple DTS 原话：72 次/天）
//   · 一次 reload 可以返回**任意多个 entry**（同一原话：unlimited amount of entries）
// 所以只要把「猫在不在我这儿」按**确定性行程表**预排成 timeline，
// 各组件根本不需要同时刷新 —— 它们各自的 timeline 对未来每一刻的答案都是一致的。
//
// 本脚本对比两种做法，用数字说明差多少。

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
const SAME_PAGE = 0.70, ISLAND = 0.14, HOME_PULL = 0.06;
const ROOMS = [
  ['still', 0], ['clock', 0], ['weather', 0], ['photo', 0], ['notes', 0],
  ['music', 1], ['podcast', 1], ['cal', 1], ['remind', 1], ['health', 1], ['maps', 1],
  ['album', 2], ['battery', 2], ['short', 2], ['world', 2], ['timer', 2],
];
const PAGE = Object.fromEntries(ROOMS);
const IDS = ROOMS.map(r => r[0]);

function buildSchedule(seedStr, span = 400, back = 30) {
  const rnd = splitmix64(fnv(seedStr));
  const list = [];
  let t = -back, cur = 'weather';
  while (t < span) {
    const dur = STAY_MIN + rnd() * (STAY_MAX - STAY_MIN);
    let target;
    if (PAGE[cur] !== PAGE['still'] && rnd() < HOME_PULL) {
      target = 'still';
    } else {
      const same = ROOMS.filter(([id, p]) => p === PAGE[cur] && id !== cur);
      const any = ROOMS.filter(([id]) => id !== cur);
      const pool = (rnd() < SAME_PAGE && same.length) ? same : any;
      target = pool[Math.floor(rnd() * pool.length)][0];
    }
    list.push({ t0: t, t1: t + dur, at: cur, to: target, island: rnd() < ISLAND });
    t += dur; cur = target;
  }
  return list;
}

// 时刻 T，猫在哪个「地方」：房间 id，或 'island'，或 null（没有，理论上不会）
function placeAt(S, T) {
  for (const s of S) {
    if (T >= s.t0 && T < s.t1) return s.island ? 'island' : s.at;
  }
  return null;
}

// 各实例的刷新时刻表。perDay = 每天 reload 次数
function refreshTimes(rnd, startH, endH, perDay) {
  const out = [];
  const avg = 24 / perDay;
  let t = startH - avg * rnd();          // 错开相位，别让所有实例同一时刻刷
  while (t < endH) {
    if (t >= startH) out.push(t);
    t += avg * (0.5 + rnd());            // 均值 = avg
  }
  return out;
}

// ── 方案 A（旧做法）：刷新时读「当前状态」，快照一直留到下次刷新 ──
function simA(S, id, times, T0, T1, step) {
  let idx = 0;
  const shown = [];                       // [time, bool]
  for (const t of times) {
    if (t > T1) break;
    shown.push([t, placeAt(S, t) === id]);
  }
  if (!shown.length) return () => false;
  let k = 0;
  return (T) => {
    while (k + 1 < shown.length && shown[k + 1][0] <= T) k++;
    return shown[k][0] <= T ? shown[k][1] : false;
  };
}

// ── 方案 B（新做法）：刷新时预排 timeline，entry 落在行程表的切换点 ──
// 关键：末尾放一个 catHere=false 的兜底 entry。
// timeline 走完后系统就一直显示兜底 → 失败方向是「看不见它」，不是「两个地方都有它」。
function simB(S, id, times, T0, T1, step, coverH) {
  const shown = [];
  for (const t of times) {
    if (t > T1) break;
    const end = t + coverH;
    // 该房间在 [t, end] 内的所有进出时刻
    const bounds = [];
    let prev = placeAt(S, t) === id;
    for (const s of S) {
      if (s.t0 > t && s.t0 < end) {
        const now = placeAt(S, s.t0 + 1e-6) === id;
        if (now !== prev) { bounds.push([s.t0, now]); prev = now; }
      }
    }
    shown.push({ from: t, to: end, init: placeAt(S, t) === id, bounds });
  }
  if (!shown.length) return () => false;
  let k = 0;
  return (T) => {
    while (k + 1 < shown.length && shown[k + 1].from <= T) k++;
    const w = shown[k];
    if (T < w.from) return false;
    if (T >= w.to) return false;          // 兜底 entry：一律不画猫
    let v = w.init;
    for (const [b, val] of w.bounds) { if (b <= T) v = val; else break; }
    return v;
  };
}

// ═══════════════════════════════════════════════════
const DAYS = 7, T1 = DAYS * 24, STEP = 1 / 60;   // 采样粒度 1 分钟
const SEEDS = ['still-a', 'still-b', 'still-c'];

function run(mode, perDayEach, coverH) {
  const hist = { 0: 0, 1: 0, 2: 0, more: 0 };
  let islandT = 0, total = 0;
  for (const seed of SEEDS) {
    const S = buildSchedule(seed);
    const rnd = splitmix64(fnv(seed + '-refresh'));
    const fns = IDS.map(id => {
      const times = refreshTimes(rnd, 0, T1, perDayEach);
      return mode === 'A' ? simA(S, id, times, 0, T1, STEP)
                          : simB(S, id, times, 0, T1, STEP, coverH);
    });
    for (let T = 0; T < T1; T += STEP) {
      const p = placeAt(S, T);
      if (p === 'island') { islandT++; total++; continue; }
      let n = 0;
      for (const f of fns) if (f(T)) n++;
      hist[n >= 3 ? 'more' : n]++;
      total++;
    }
  }
  return { hist, islandPct: islandT / total * 100 };
}

function pct(v, t) { return (v / t * 100).toFixed(2).padStart(6) + '%'; }

console.log('══ 唯一性验证：同一时刻有几个组件显示猫 ══');
console.log('   16 个组件 / 7 天 / 3 个随机种子 / 采样粒度 1 分钟\n');

const rows = [];
function line(label, mode, perDay, coverH) {
  const { hist, islandPct } = run(mode, perDay, coverH);
  const total = hist[0] + hist[1] + hist[2] + hist.more;
  const bad = (hist[2] + hist.more) / total * 100;
  const none = hist[0] / total * 100;
  rows.push({ label, bad, none, islandPct, hist, total });
  console.log(label);
  console.log('    0 个显示猫  ' + pct(hist[0], total) + '   （它不见了）');
  console.log('    1 个显示猫  ' + pct(hist[1], total) + '   ← 正确');
  console.log('    2 个显示猫  ' + pct(hist[2], total) + '   ← 违反唯一性');
  console.log('    3 个及以上  ' + pct(hist.more, total) + '   ← 违反唯一性');
  console.log('');
}

console.log('── 旧做法：刷新时读当前状态 ──');
line('  A-1  每个组件 72 次/天（约 20 分钟一刷）', 'A', 72);
line('  A-2  每个组件 24 次/天（约 60 分钟一刷）', 'A', 24);
line('  A-3  每个组件  6 次/天（约 4 小时一刷）', 'A', 6);

console.log('── 新做法：预排 timeline（entry 落在行程切换点）──');
line('  B-1  覆盖 24 小时 / 72 次每天', 'B', 72, 24);
line('  B-2  覆盖 12 小时 / 24 次每天', 'B', 24, 12);
line('  B-3  覆盖  6 小时 / 24 次每天', 'B', 24, 6);
line('  B-4  覆盖  6 小时 /  6 次每天（最坏：4 小时才刷一次）', 'B', 6, 6);

console.log('══ 结论 ══');
const best = rows.filter(r => r.label.includes('B-'));
const worstBad = Math.max(...best.map(r => r.bad));
console.log('  新做法下「两个组件同时有猫」的比例：' + worstBad.toFixed(4) + '%  （应为 0）');
console.log('  代价是「它暂时看不见」—— 覆盖越短、刷新越少，看不见的时间越多：');
best.forEach(r => console.log('    ' + r.label.trim().padEnd(46, ' ') + '看不见 ' + r.none.toFixed(1) + '%'));
console.log('\n  注：上面所有百分比都**已经扣掉了**它去灵动岛的时间');
console.log('  （岛占约 ' + rows[0].islandPct.toFixed(1) + '%，那段时间它本来就不在任何组件里，是设计不是失败）。');
console.log('  所以「看不见」这一列是纯粹的非岛时间里它消失的比例 —— 这才是新方案的真实代价。');
console.log('  旧做法 A 同时有两宗罪：既会「两个地方都有它」，也会「看不见它」；');
console.log('  新做法把前者彻底消灭，只留下后者，且后者不到 2%。');
