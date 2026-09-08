// 参数扫描：homePull × samePageRate 怎么配才对
// 目标（按优先级）：
//   1. 7 天内 16 个组件都要被去过  —— 有组件从没去过，留痕就没意义了
//   2. 跨页率落在 15~25%           —— 太高就变成看翻页动画，不是穿梭
//   3. 第 0 页（你打开时看到的那一屏）被待的时间占 30~45%
//      —— 太低＝它总不在家；太高＝别的页白做了

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

const ROOMS = [
  ['still', 0], ['clock', 0], ['weather', 0], ['photo', 0], ['notes', 0],
  ['music', 1], ['podcast', 1], ['cal', 1], ['remind', 1], ['health', 1], ['maps', 1],
  ['album', 2], ['battery', 2], ['short', 2], ['world', 2], ['timer', 2],
];
const PAGE = Object.fromEntries(ROOMS);
const HOME = 'still';

function build(homePull, samePage, span = 168, back = 26) {
  const rnd = splitmix64(fnv('still-ios-widgets'));
  const bool = p => rnd() < p;
  const list = [];
  let t = -back, cur = 'weather';
  while (t < span) {
    const dur = 1.0 + rnd() * 2.4;
    const curPage = PAGE[cur];
    let target;
    if (curPage !== PAGE[HOME] && bool(homePull)) {
      target = HOME;
    } else {
      const same = ROOMS.filter(([id, p]) => p === curPage && id !== cur);
      const any = ROOMS.filter(([id]) => id !== cur);
      const pool = (bool(samePage) && same.length) ? same : any;
      target = pool[Math.floor(rnd() * pool.length)][0];
    }
    list.push({ t0: t, t1: t + dur, at: cur, to: target });
    t += dur; cur = target;
  }
  return list;
}

// ⚠️ 2026-09-03 重写：行程表改成「岛是段开头的一小段」之后，
//    每段多消耗一次 rnd()，整条随机序列往后错了一位 ——
//    之前扫出来的 homePull 0.06 / samePageRate 0.70 已经失效
//    （跨页从 22.7% 涨到 30.9%，7 天开始漏组件）。
//    凡是改动 build() 里的 rnd() 调用次数，都必须重跑这个脚本。
//    另外时间基准也改了：现在用真实 epoch 小时，不再用 -26...600。

const HOUR_EPOCH = Date.now() / 1000 / 3600;
const ISLAND_RATE = 0.14, ISLAND_MIN = 0.15, ISLAND_MAX = 0.60;

// freshBias：跨页时有多大概率优先挑「最久没去过的那几个」。
// 纯随机游走在 81 次访问 / 16 房间下必然漏掉一两个（这是统计规律，调 homePull 调不好），
// 漏掉的那个组件就永远是「它还没来过」—— 一块死组件。
// 加了这个倾向后覆盖率才稳定。
const FRESH_BIAS = 0.5;
const FRESH_POOL = 4;

function evaluate(homePull, samePage) {
  // 多个 seed 取平均，避免被单条时间线带偏
  let cross = 0, n = 0, missed = 0, page0Hours = 0, totalHours = 0;
  for (const salt of [0, 1, 2, 3, 4, 5, 6, 7]) {
    const rnd = splitmix64((fnv('still-ios-widgets') ^ salt) >>> 0);
    const bool = p => rnd() < p;
    const list = [];
    const lastSeen = {};                 // roomId -> 它最后一次「离开」的时刻
    let t = HOUR_EPOCH - 26, cur = 'weather';
    while (t < HOUR_EPOCH + 168) {
      const dur = 1.0 + rnd() * 2.4;
      const curPage = PAGE[cur];
      let target;
      if (curPage !== PAGE[HOME] && bool(homePull)) {
        target = HOME;
      } else {
        const same = ROOMS.filter(([id, p]) => p === curPage && id !== cur);
        const any = ROOMS.filter(([id]) => id !== cur);
        let pool;
        if (bool(samePage) && same.length) {
          pool = same;
        } else if (bool(FRESH_BIAS)) {
          // 最久没去过的几个里挑 —— 保证没有组件永远空着
          pool = any.slice()
            .sort((a, b) => (lastSeen[a[0]] ?? -1e9) - (lastSeen[b[0]] ?? -1e9))
            .slice(0, Math.min(FRESH_POOL, any.length));
        } else {
          pool = any;
        }
        target = pool[Math.floor(rnd() * pool.length)][0];
      }
      // 和 Schedule.build 保持一致：多这一次调用会改变后续所有随机数
      if (bool(ISLAND_RATE)) rnd();
      list.push({ t0: t, t1: t + dur, at: cur, to: target });
      lastSeen[cur] = t;
      t += dur; cur = target;
    }
    const win = list.filter(s => s.t1 > HOUR_EPOCH && s.t0 < HOUR_EPOCH + 168);
    const hit = {};
    for (const s of win) {
      if (PAGE[s.at] !== PAGE[s.to]) cross++;
      hit[s.at] = (hit[s.at] || 0) + 1;
      totalHours += s.t1 - s.t0;
      if (PAGE[s.at] === 0) page0Hours += s.t1 - s.t0;
      n++;
    }
    missed += ROOMS.filter(([id]) => !hit[id]).length;
  }
  return {
    cross: cross / n * 100,
    missed: missed / 8,
    page0: page0Hours / totalHours * 100,
  };
}

console.log('homePull  samePage   跨页率   7天漏掉组件   第0页占时   评价');
console.log('─'.repeat(74));

const rows = [];
for (const hp of [0.06, 0.10, 0.14, 0.18, 0.24]) {
  for (const sp of [0.70, 0.78, 0.85]) {
    const r = evaluate(hp, sp);
    const ok1 = r.missed === 0;
    const ok2 = r.cross >= 15 && r.cross <= 25;
    const ok3 = r.page0 >= 30 && r.page0 <= 45;
    const score = (ok1 ? 1 : 0) + (ok2 ? 1 : 0) + (ok3 ? 1 : 0);
    rows.push({ hp, sp, ...r, score, ok1, ok2, ok3 });
  }
}
for (const r of rows) {
  const mark = r.score === 3 ? '  ✅ 三项全中' : (r.score === 2 ? '  ○  ' + [!r.ok1 && '漏组件', !r.ok2 && '跨页偏', !r.ok3 && '第0页偏'].filter(Boolean).join('/') : '  ✗');
  console.log(
    String(r.hp).padEnd(9) + ' ' + String(r.sp).padEnd(10) +
    (r.cross.toFixed(1) + '%').padStart(7) + '   ' +
    r.missed.toFixed(1).padStart(8) + '   ' +
    (r.page0.toFixed(1) + '%').padStart(9) + mark
  );
}
const best = rows.filter(r => r.score === 3).sort((a, b) => Math.abs(a.cross - 20) - Math.abs(b.cross - 20))[0];
console.log('');
if (best) console.log('推荐：homePull=' + best.hp + '  samePageRate=' + best.sp);
else {
  const b2 = rows.sort((a, b) => b.score - a.score)[0];
  console.log('没有三项全中的组合，最接近的是 homePull=' + b2.hp + ' samePageRate=' + b2.sp);
}
