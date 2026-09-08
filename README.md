# 还在 Still · iOS

把「家 = 你的 iPhone」这件事落到原生。

> ⚠️ **这份代码没有在真机上编译过。** 写它的机器是 Windows，没有 Xcode，编译不了。
> 静态检查（括号平衡、跨文件符号引用）过了，引擎行为用 node 复刻跑过模拟，
> 但**第一次在 Xcode 里 Build 大概率会报错**。
>
> **没有 Mac 也能先验编译**：推到 GitHub，Actions 会用真 Mac 帮你 build（模拟器免签名，
> 不需要开发者账号）。见下面「不用 Mac 怎么验证」。
>
> 上 Mac 后先读 [`Docs/BUILD_ON_MAC.md`](Docs/BUILD_ON_MAC.md)，
> 里面列了「必须改的三件事」和「我预计会踩的坑」。

---

## 不用 Mac 怎么验证

`.github/workflows/ios-build.yml` 已经写好了。推到 GitHub 后：
**Actions → iOS 编译验证 → Run workflow**，等 5~10 分钟。

它跑在 GitHub 的 macOS 虚拟机上（装了真 Xcode），编译到模拟器——**不签名，所以不需要 Apple 开发者账号**。

| 能验出来 | 验不出来 |
|---|---|
| 语法错、类型错、符号找不到 | 猫画得对不对 |
| target membership 配错 | 走路手感、帧率 |
| `@main` 重复 | 灵动岛（模拟器没硬件，只有锁屏横幅） |
| `AppIntent` / `AppIntentTimelineProvider` 签名对不对 | 组件的房间选择列表（要人点） |
| `AppEnum` 的 16 个 case 有没有写全 | 真机上系统到底有没有按 timeline 刷 |

花费：macOS runner 按 10 倍计费，一次约扣 50~100 分钟额度。
免费账号每月 2000 分钟够跑 20~40 次。**仓库设成 public 则完全免费。**

> 想装到真机上必须 Apple 开发者账号 **$99/年** + 配证书。
> 那是另一件事，等你要掏这钱时再说。

---

## 这一版是什么

不是 Android 版的移植。iOS 给不了 Android 那些能力，所以形态必须重做：

| | Android | iOS |
|---|---|---|
| 家 | 用户的手机 | 用户的手机 |
| 房间 | **真实安装的 App**（读得到前台包名） | **桌面上的 16 个小组件** |
| 猫在哪 | 跨 App 系统浮层 | App 内的桌面画布 |
| App 之外 | 浮层一直在 | 只有灵动岛（Live Activity） |
| 留痕 | 改图标、往相册加照片 | 组件角落的爪印、相册 add-only |

**换掉「房间 = 真实 App」不是偷懒，是硬约束**：iOS 没有任何 API 能告诉你当前前台是哪个 App
（Apple DTS 官方答复 No；Screen Time API 只给聚合时长且是 managed capability）。
既然拿不到真实 App，就自己做一套长得一模一样的小组件——**房间变成它真的能住的地方**。

---

## 唯一性：这是这一版的核心

> **任何时刻，16 个小组件 + 灵动岛里，只有一处会出现这只猫。**
> 它在这一处，就不在别处。就像真的猫——你在这个房间找到它，它就不在客厅。

这个要求一开始被我判成「做不到」，**那个判断是错的**，已推翻。实现思路：

**不要让组件之间互相协调，让它们各自算出同一个答案。**

1. 行程表是**确定性**的，存在 App Group 里。App 和 Widget Extension 读到的是**逐字节相同**的数据。
2. 每个组件自己算一条 timeline，entry 只落在「猫进出**我这间**」的时刻上。
3. 于是任意时刻 T，每个组件的答案都源自同一个 `place(T)`——**必然只有一个为真**。

关键事实（Apple DTS 官方答复）：**每天 72 次的刷新预算，限制的是 reload 次数，不是 entry 数量。**
所以一条 timeline 可以只刷新一次、但里面预先排好一整天的进出时刻——**entry 数量不限**。
这是整个方案成立的前提。

**失效方向是设计好的**：每条 timeline 的最后一个 entry 恒为 `here: false`。
预算耗尽时，结果是「你看不见它」，**永远不是「出现两只」**。

```
实测：16 个组件 × 7 天 × 逐分钟扫描（Tools/_schedule_check.js）
  1 个组件画猫    97.79%   ← 正确
  0 个组件画猫     0.00%
  2 个组件画猫     0.0000%  ← 违反唯一性
  3 个及以上       0.0000%
  （已排除在岛里的 2.2% 时间 —— 那时它本来就不在任何组件里）
```

### 灵动岛是第 17 个房间

和小组件**平级**，不是「额外功能」。它在岛里时，所有组件都不画猫 —— 唯一性照样成立。

岛比组件好看的地方：**组件是死图，岛上的它是会动的**。
每换一次姿势会触发一次系统的岛过渡动画，所以它在岛里只做安静的小动作（坐、张望、舔毛，5~11 秒一个）。

### 找不找得到，是特性不是 bug

16 个组件是**推荐上限，越多越好**。找不到它是正常的——
真的猫也会钻到不知道哪个角落去。你要做的是去翻，不是让它随叫随到。

---

## 目录

```
Still-iOS/
├── project.yml                 XcodeGen 配置（一条命令生成 .xcodeproj）
├── .github/workflows/
│   └── ios-build.yml           云端 Mac 帮你验编译（不需要本地 Mac）
├── Sources/
│   ├── App/
│   │   ├── Shared/
│   │   │   ├── StillConfig.swift        常量 + 16 个组件定义 + 确定性随机
│   │   │   ├── Schedule.swift           ★★ 行程表：唯一性的唯一真相来源
│   │   │   ├── PetEngine.swift          ★ 引擎：走路、动作循环、呼唤
│   │   │   ├── SharedStore.swift        App Group 通道 + 灵动岛桥接
│   │   │   └── StillActivityAttributes.swift   灵动岛数据契约（两个 target 共用）
│   │   ├── Cat/CatView.swift            毛毡猫，SwiftUI Path 复刻的 8 个姿势
│   │   ├── Home/
│   │   │   ├── HomeCanvasView.swift     3 页桌面 + 网格布局
│   │   │   ├── WidgetCardView.swift     16 个组件的外观 + 爪印
│   │   │   └── CatLayerView.swift       猫这一层：纵深、影子、动作微动
│   │   ├── Island/StillActivity.swift   灵动岛 + 锁屏的 UI（属 Widget target）
│   │   ├── Panel/StatusPanelView.swift  时间机器、撞见概率、呼唤
│   │   ├── ContentView.swift
│   │   └── StillApp.swift
│   └── Widget/StillWidget.swift         真小组件（可配置房间）+ WidgetBundle
├── Docs/
│   └── BUILD_ON_MAC.md         ★ 上 Mac 第一步看这个
└── Tools/
    ├── _check.js               静态自检（括号 + 符号引用）
    ├── _schedule_check.js      ★ 行程表 + 逐分钟唯一性扫描
    ├── _uniqueness.js          新旧方案对比（为什么必须预排 timeline）
    ├── _tune.js                参数扫描：homePull × samePageRate
    └── _sim.js                 动作循环模拟
```

> **`Schedule.swift` 是本项目的地基。** 它同时被主 App 和 Widget Extension 编译，
> 两边读同一份数据、跑同一套确定性算法——这是唯一性能成立的唯一原因。
> 改它之前先读文件头那段注释。
---

## 三个 Target 的关系

```
┌─ 主 App ────────────────┐        ┌─ Widget Extension ──────────┐
│  桌面画布（会动的猫）      │        │  StillWidget   小组件（静态）  │
│  PetEngine              │        │  StillLiveActivity 灵动岛 UI  │
│  IslandBridge ──────────┼──┐     │                              │
└─────────────────────────┘  │     └──────────────────────────────┘
                             │                    │
                        ActivityKit          ActivityKit
                             │                    │
                        ┌────▼────────────────────▼────┐
                        │  App Group: group.com.still.app │
                        │  （唯一的数据通道）              │
                        └───────────────────────────────┘
```

**Target Membership 是最容易配错的地方**：

| 文件 | 主 App | Widget Ext |
|---|:---:|:---:|
| `Sources/App/Shared/*` | ✅ | ✅ |
| `Sources/App/Cat/CatView.swift` | ✅ | ✅ |
| `Sources/App/Home/WidgetCardView.swift` | ✅ | ✅（为了 PawMark） |
| `Sources/App/Home/{HomeCanvas,CatLayer}View.swift` | ✅ | ❌ |
| `Sources/App/Island/StillActivity.swift` | ❌ | ✅ |
| `Sources/Widget/*` | ❌ | ✅ |

用 XcodeGen 的话这些在 `project.yml` 里已经写好了。

---

## 引擎在做什么

**两层，别混为一谈**：

**第一层 · 行程表（确定性，写死在时间里）**　—— 见 `Schedule.swift`
事先算出未来若干天它在哪个组件、什么时候挪窝、去哪。
这样小组件（独立进程、只拿得到快照）才能回答「它现在在哪」，时间机器和俯瞰图也才有意义，
**唯一性也才有东西可依附**。

时间基准是**绝对小时**（`Unix epoch / 3600`），不是相对小时。
这一点踩过坑：用相对小时时 `segment(at:)` 永远查不到，猫**一次都没自己挪过窝**。

行程表**只追加、不覆写**。中途改写会让已经发出去的 timeline 和新的对不上，唯一性立刻破。
所以 `call()` / `nfcRecall()` **不换房间**，只让它走到你跟前。

**第二层 · 动作循环（实时，进 App 才跑）**
它在一个组件里不是摆个姿势干等着，而是循环做 6 件事：睡觉、舔毛、伸懒腰、扑着玩、坐着发呆、抬头张望。
每个动作几秒就是几秒，**不跟着演示倍速压缩**——和走路一个道理。

### 实测数字（`node Tools/_schedule_check.js`）

```
行程表（未来 7 天）
  挪窝 77 次，平均停留 2.22 小时，一天挪 10.8 次
  7 天里 16 个组件全部去过，每个平均 4.8 次
  跨页 19.5%
  在灵动岛 2.2% 的时间（10 次进岛，平均每次 22 分钟）

小组件 timeline（8 小时预排）
  单个组件 2~4 个 entry，平均 2.5 个
  16 个组件全排一遍共 40 个 entry
  → 一天刷一次就够，远在 72 次预算之内

动作（按占用时间算）
  睡觉 37%  坐着 26%  舔毛 24%  其余 13%
  平均每个动作 6.2 秒
```

---

## 用起来是什么流程（用户侧）

1. 长按桌面 → 加组件 → 选 Still。
2. **长按刚加的组件 → 编辑 → 选一个房间。** 这一步**不能省**。
3. 想有几个房间就加几个，最多 16 个。**推荐加满。**

第 2 步为什么必须手动：WidgetKit **没有实例 ID**。Apple 官方文档原话——
*"users can add multiple instances... your provider needs a way to differentiate which instance"*。
唯一的区分方式就是 `AppIntentConfiguration` + 用户手动选房间。绕不过去。

选了房间的组件会显示「它在这儿 / 上次来是……」；没选的会显示提示。

**还没接的一件事**：主 App 目前不知道用户放了哪几个组件。要读得用
`WidgetCenter.shared.currentConfigurations()`（iOS 14+，可拿到每个组件及其 intent 里选的房间）。
**留痕统计、「它去过哪」、onboarding 的「你还剩几个房间没加」都建立在这上面** —— 这是下一个该做的。

---

## 六条原理在 iOS 上还剩几条

| 原理 | iOS 上的情况 |
|---|---|
| 双真相 | ✅ 手机是真的，组件里的猫也是真的（样式化渲染，不是功能模拟） |
| 自由游走 | ⚠️ 出不了 App；但它自己在 16 个房间之间挑地方住，你说了不算 |
| 概率召回 | ✅ `RECALL_RATE = 0.68`；但**只让它走到你跟前，不把它拽到另一个房间** |
| 自主换房 | ✅ 它会自己挑组件住下，还会自己钻灵动岛 |
| 留痕 | ⚠️ 组件角落的爪印可以；改不了别的 App 的图标/照片 |
| 不读隐私 | ✅ 全程不碰你的任何内容 |

---

## 已知边界

- **小组件里没有会动的猫。** 小组件是系统渲染的静态快照，刷新时机系统说了算。
  技术上有野路子能到 8fps，但会失效，不值得。小组件的定位是**证据链**，不是舞台。
  会动的只有两处：App 内的画布，和灵动岛。
- **最坏情况是你看不见它，不是看见两只。** 预算耗尽、行程表断档、组件刚加还没刷——
  这些情况下它只是不在那个组件里。失效方向是设计死的（timeline 末位恒为 `here: false`）。
- **组件要一个一个手动选房间。** WidgetKit 无实例 ID，只能靠用户长按编辑。
  这一步没法自动化，得在产品引导里说清楚。
- **灵动岛有审核风险。** Apple 要求 Live Activity 只用于「有明确起止的进行中任务」，
  宠物状态算擦边。真上架要准备说明话术。另外 12 小时上限、4KB payload 上限。
- **扑猎时猫会挡住组件内容。** 它从组件底部朝偏上的位置扑过去，会遮住天气图标之类。
  嫌挡的话让 `playHunt` 扑向组件边缘而不是中间。
- **Live Activity 在模拟器上看不到岛**（没硬件），只有锁屏横幅。真机 iPhone 14 Pro+ 才有。
- **改 `Schedule.build()` 里 `rnd()` 的调用次数，所有调过的参数全部作废。**
  每多一次随机调用，整个随机序列就整体偏移。已经踩过一次：加 `islandHours` 多了一次 `rnd()`，
  跨页率从 22.7% 悄悄跳到 30.9%，7 天开始漏组件。改完必须重跑 `Tools/_tune.js`。
