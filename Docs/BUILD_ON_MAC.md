# 拿到 Mac 之后：从零到跑起来

这份代码**没有在 Xcode 里编译过**（写它的机器是 Windows）。
所以下面不会假装"打开就能跑"，而是照着"第一次 Build 大概率报错"来写。

预计耗时：**顺利 20 分钟，踩坑 1 小时。**

---

## 0. 前提

- Mac（Intel 或 Apple Silicon 都行）
- Xcode **15.0 以上**（低于这个版本编译不过，用了 iOS 17 的 API）
- 一台 iPhone（**模拟器看不到灵动岛**，Live Activity 只有锁屏横幅）
- Apple 账号：免费的就够（7 天重签一次）；有付费开发者账号更好

---

## 1. 先做这件事：不用 Mac 也能验编译（GitHub Actions）

这份代码最大的风险不是设计，是**它一行都没编译过**。
在借到 Mac 之前，先花 10 分钟把这个未知消掉。

**原理**：GitHub 提供真的 macOS 虚拟机（runner），上面装着 Xcode。
你把代码推上去，云端的 Mac 帮你 build，把报错回传。

**为什么不需要 Apple 开发者账号**：编译到**模拟器**不签名。
签名只为"装到真机"服务。所以免费 GitHub 账号就够。

**步骤**：

1. 建一个 GitHub 仓库，把 `Still-iOS/` 整个目录推上去
   （`.github/workflows/ios-build.yml` 要一起推，GitHub 只认这个路径）
2. 仓库页面 → **Actions** → 左边选 **iOS 编译验证** → 右边 **Run workflow**
3. 等 5~10 分钟。绿了就是能编译；红了点进去看 `build.log`
4. 绿的还能下载 `Still-simulator-app` 产物（模拟器用的 .app，装不到手机上）

> 如果 `Still-iOS` 只是你仓库里的一个子目录，把 `.github/` 挪到**仓库根**。
> workflow 里写了自动定位，两种摆放都认。

**花费**（2026-09 查证）：macOS runner 按 **10 倍**计费，一次 build 约扣 50~100 分钟额度。
免费账号每月 2000 分钟，私有仓库够跑 20~40 次。
**仓库设成 public 则完全免费、不限量**——代码本来也没什么可保密的，推荐这么做。

**能验出什么 / 验不出什么**：

| 能 | 不能 |
|---|---|
| 语法错误、类型错误、符号找不到 | 猫画得对不对 |
| target membership 有没有配错 | 走路手感 |
| `@main` 重复 | 灵动岛（模拟器看不到岛，只有锁屏横幅） |
| App Group / entitlements 是否合法 | 帧率 |
| `AppIntent` / `AppIntentTimelineProvider` 的签名对不对 | 组件的房间选择列表（要人点） |
| `AppEnum` 的 16 个 case 有没有写全 | 真机上系统到底有没有按 timeline 刷 |

**想装到真机上**：必须 Apple 开发者账号 **$99/年**，配好证书和 Provisioning Profile，
把 `.p12` 和 profile 存成仓库 Secrets，再改 workflow 里的签名步骤。
这一步我没写，等你决定要不要掏这 99 美元再说。

---

## 2. 生成工程：两条路

### 路 A · XcodeGen（推荐，3 分钟）

```bash
brew install xcodegen
cd Still-iOS
xcodegen generate
open Still.xcodeproj
```

`project.yml` 里已经写好了两个 target、App Group、Info.plist 键。

### 路 B · 手动建（15 分钟，XcodeGen 装不上时走这条）

1. **File → New → Project → iOS → App**
   - Product Name: `Still`
   - Interface: **SwiftUI**，Language: **Swift**
   - 取消勾选 "Include Tests"
2. 把 `Sources/` 整个拖进工程，**取消** "Copy items if needed"（选 Create groups）
3. **File → New → Target → Widget Extension**
   - 命名 **`StillWidgetExtension`**
     ⚠️ 别只叫 `StillWidget`。我们有个 struct 也叫 `StillWidget`，
     和 target（也就是模块）同名会报「模块与类型同名」的歧义错。
     手动建工程时这里如果已经手滑写成了 `StillWidget`，去
     Build Settings → Product Module Name 改成 `StillWidgetExtension` 即可。
   - 取消 "Include Live Activity" 和 "Include Configuration Intent"
     > **别误会第二项**：我们用的是 `AppIntentConfiguration` + `AppIntent`，
     > 是**纯 Swift 代码**（在 `Schedule.swift` 里），
     > 不需要 Xcode 生成的 `.intentdefinition` 文件。这里取消勾选是对的。
4. **删掉 Xcode 自动生成的** `StillWidget.swift`、`StillWidgetBundle.swift`、`StillApp.swift`、`ContentView.swift`、`Assets.xcassets`（如果不放心就先 Build 一次确认模板能跑，再删）
5. 按 README 里那张 **Target Membership 表** 逐个勾文件
6. 两个 target 的 Deployment Target 都设成 **iOS 17.0**

---

## 3. 必须改的三件事（不改一定跑不起来）

### ① Bundle Identifier + 签名

改 `project.yml` 里这两行（已经显式写死了，别让 XcodeGen 拿前缀去拼）：

```yaml
Still:                 productBundleIdentifier: com.你的名字.still
StillWidgetExtension:  productBundleIdentifier: com.你的名字.still.widget
```

> ⚠️ **Widget 的 Bundle ID 必须是「主 App 的 ID + 后缀」**，这是 Apple 的硬规则。
> 写成 `com.你的名字.widget` 这种平级名字，签名阶段必报错。

改完重新跑 `xcodegen generate`。

**只在模拟器上跑的话，这一节可以整段跳过** —— 模拟器不签名。
要装真机才需要，那时两个 target → **Signing & Capabilities → Team** 选你的账号。

> 第一次连真机会报 "Untrusted Developer"。
> 手机上：**设置 → 通用 → VPN与设备管理 → 信任**。

### ② App Group（两个 target 都要加，且字符串必须一模一样）

**Signing & Capabilities → + Capability → App Groups**，加：

```
group.com.still.app
```

然后把 `Sources/App/Shared/StillConfig.swift` 里的改成同一个：

```swift
static let appGroup = "group.com.still.app"
```

以及 `project.yml` 里的 `com.apple.security.application-groups`（如果走 XcodeGen）。

> **忘了配对会怎样**：不崩，但小组件永远读不到数据，一直显示默认的「它在『还在』里」。
> 这种"静默失败"最难查，所以先确认这个。

### ③ Live Activity 开关

主 App 的 Info.plist 里加：

```
NSSupportsLiveActivities = YES
```

走 XcodeGen 的话已经在 `project.yml` 里了。

---

## 4. 我预计你会遇到的坑（按可能性排序）

### 坑 1 · `@main` 重复

**症状**：`error: 'main' attribute cannot be used in a module that contains top-level code` 或 `@main attribute previously used here`

**原因**：手动建工程时 Xcode 生成的 `StillWidgetBundle.swift` 也带 `@main`。

**修**：删掉 Xcode 生成的那个，只保留 `Sources/Widget/StillWidget.swift` 里的 `StillWidgetBundle`。

---

### 坑 2 · Target Membership 配错

**症状**：`Cannot find 'CatView' in scope`（Widget target 里）
或 `Cannot find type 'StillActivityAttributes' in scope`

**对照这张表逐个勾**（文件 → File Inspector → Target Membership）：

| 文件 | 主 App | Widget Ext |
|---|:---:|:---:|
| `Shared/*`（**5 个**：StillConfig / Schedule / PetEngine / SharedStore / StillActivityAttributes） | ✅ | ✅ |
| `Cat/CatView.swift` | ✅ | ✅ |
| `Home/WidgetCardView.swift` | ✅ | ✅ |
| `Home/HomeCanvasView.swift` | ✅ | ❌ |
| `Home/CatLayerView.swift` | ✅ | ❌ |
| `Island/StillActivity.swift` | ❌ | ✅ |
| `Widget/StillWidget.swift` | ❌ | ✅ |
| `ContentView.swift` / `StillApp.swift` | ✅ | ❌ |
| `Panel/StatusPanelView.swift` | ✅ | ❌ |

> `Island/StillActivity.swift` **只**勾 Widget Ext。
> 勾了主 App 会报 `ActivityConfiguration` 相关的一堆错。

---

### 坑 3 · `#Preview` 宏报错

**症状**：`Cannot find macro 'Preview'`

**原因**：Deployment Target 低于 17.0，或者 Preview 的 Canvas 在 Widget target 上崩。

**修**：两个 target 都设 **iOS 17.0**。还不行就直接把 `#Preview { ... }` 块注释掉——它只影响预览，不影响编译。

---

### 坑 4 · 猫画歪了（不报错，但看着不对）

CatView 是从 SVG 逐点复刻的，但两处渲染差异值得截图对比：

- **描边拐角**：原版 SVG 用 `stroke-linejoin="round"`。我已经显式加了 `lineJoin: .round`，但如果耳朵尖还是显得太尖，检查 `lineStyle` 有没有作用到所有 stroke 上。
- **耳朵旋转方向**：SVG 的 `rotate(a, cx, cy)` 和 SwiftUI 的 `CGAffineTransform.rotated(by:)` 在 y 轴向下时都表现为顺时针。如果耳朵朝反方向转，`earLayer` 里的变换矩阵符号取反即可。

**验证办法**：Xcode 里打开 `CatView.swift`，右侧 Canvas 会渲染 `#Preview("全部姿势")`，8 个姿势并排。和 `still-ios-widgets.html` 在浏览器里并排对比。

---

### 坑 5 · 走路太慢 / 太快

**症状**：它走一次要十几秒，或者一闪而过。

**原因**：`Cfg.walkSecPerUnit = 9.0` 是从 Android 搬的（`animDur = dist * 9000ms`），
但 Android 的 `dist` 是全屏归一化距离，iOS 的桌面比例不一样。

**修**：调 `StillConfig.swift`：

```swift
static let walkSecPerUnit: Double = 9.0   // 调小走得快
static let walkSecMax: Double = 6.0       // 上限
```

---

### 坑 6 · 掉帧

**症状**：走路时明显卡顿，尤其老设备。

**修**（按代价从小到大）：

1. `Cfg.tickHz` 从 `30.0` 降到 `20.0`
2. `CatLayerView` 里的 `.blur(radius: engine.z * 0.9)` 去掉（实时 blur 很贵）
3. `WidgetCardView` 的 `.shadow` 去掉（16 个组件各一个阴影）

---

### 坑 7 · 灵动岛不出来

**排查顺序**：

1. 机型是 iPhone 14 Pro / 15 全系 / 16 全系吗？（**模拟器看不到岛**，只有锁屏横幅）
2. **设置 → 你的 App → 实时活动** 打开了吗？
3. 主 App Info.plist 里有 `NSSupportsLiveActivities` 吗？
4. 打断点看 `IslandBridge.supported` 是不是 `true`

**代码在哪**：`PetEngine.enterIsland()` 触发，`SharedStore.swift` 里的 `IslandBridge` 负责起 Activity。
它故意做了静默降级——起不来也不影响主 App，所以**不会报错，只会没反应**。

---

### 坑 8 · Swift 并发警告（黄色，不阻断编译）

**症状**：`Call to main actor-isolated initializer 'init()' in a synchronous nonisolated context; this is an error in Swift 6`

**位置**：`ContentView.swift` 的 `@StateObject private var engine = PetEngine()`
（`PetEngine` 标了 `@MainActor`）。

**现状**：Swift 5 语言模式下这只是**警告，能跑**。

**如果哪天切到 Swift 6 报成 error**，两个改法选一个：

```swift
// A. 给整个 View 标 MainActor
@MainActor struct ContentView: View { ... }

// B. 让引擎的 init 不隔离（Swift 5.10+）
@MainActor final class PetEngine: ObservableObject {
    nonisolated init() { ... }
}
```

---

### 坑 9 · 小组件不选房间就永远是空的

**症状**：组件加上了，但一直显示「还没选房间」或者永远是「它不在这儿」。

**原因**：WidgetKit **没有实例 ID**。Apple 官方文档原话——
*"users can add multiple instances... your provider needs a way to differentiate which instance"*。
我们靠 `AppIntentConfiguration` 让用户手选房间来区分，**这一步不能省。**

**正确流程**（这是用户流程，也是你的验收流程）：

1. 长按桌面 → 加组件 → 选 Still
2. **长按刚放上的组件 → 编辑（Edit Widget）→ 选一个房间**
3. 想有几个房间就重复几次，最多 16 个

> 如果你在模拟器里长按没反应：模拟器上长按要用鼠标按住不放约 1 秒，
> 或者用 `Hardware → Long Press` 的替代方式。

**代码在哪**：`Schedule.swift` 底部的 `RoomOption`（AppEnum，16 个 case）和
`SelectRoomIntent`（`WidgetConfigurationIntent`）。
`StillWidget.swift` 的 `recommendations()` 提供 5 个预设，编辑列表里能看到全部 16 个。

---

### 坑 10 · 怎么验收「只有一个组件画猫」

这是整个项目最核心的一条要求，得有可执行的验收办法，不能靠"看着像"。

**第一步：先在 node 里验（不需要真机）**

```bash
node Tools/_schedule_check.js
```

看最后那一节「逐分钟扫描」：`2 个组件画猫` 和 `3 个及以上` 必须都是 `0.0000%`。
现在的输出是 `1 个 97.79% / 0 个 0.00% / 2 个 0.0000%`。
（剩下的 2.2% 是它在灵动岛里，那时它本来就不在任何组件里。）

**第二步：真机上验（node 验不出来的是"系统到底有没有按 timeline 刷"）**

1. 加 **4 个** 组件，选 4 个不同房间
2. 等一次自然刷新（或者进 App 触发 `WidgetReloader`）
3. **截图桌面，数一下有几个组件里有猫**
4. 重复 10 次不同时间

只要有任意一次出现两个，就是系统没按 timeline 走——回来查
`StillWidget.swift` 的 `timeline(for:in:)`，重点看 entry 的 `date` 有没有落到
`Schedule.moments()` 给的边界上。

> **注意别验错方向**：0 个组件画猫是**正常的**（它在岛里，或者行程表暂时没覆盖那个房间）。
> 唯一性只禁止"2 个及以上"，不禁止"0 个"。

---

## 5. 第一次跑起来，你应该看到什么

1. 打开 App，**什么都不用点**
2. 假状态栏下面是一屏 iOS 风格的小组件（4 列 × 6 行）
3. 猫在其中一个组件里，**在做某个动作**（睡觉在呼吸、舔毛头在动、扑着玩时那个组件会抖）
4. 下面是状态面板，写清楚「它在「XX」里，在舔毛」

**默认 300× 演示速度**：平均 **27 秒**挪一次窝，每次走 4~6 秒。
切到 1× 就是真实节奏——平均 2.2 小时挪一次，你会等到睡着。

**第一次挪窝要等多久**：取决于它当前在时段的哪个位置，最多 27 秒。
等不及就点 **「跳到它下次挪窝」**。

### 然后：把组件放上桌面（这才是真正的产品形态）

上面的画布只是**给你看引擎在跑**。真正的产品是这样的：

1. 退回桌面，长按 → 加 16 个 Still 组件，每个**长按 → 编辑 → 选一个不同的房间**
   （嫌麻烦先加 4 个也行，但 16 个才是设计的样子）
2. 退出 App，等几分钟
3. **去翻。** 大多数组件是空的（显示爪印 + "上次来…"），只有一个里面有猫
4. 过一阵子再翻，它已经换地方了

**找不到它是正常的，这是特性。** 真的猫也会钻到你想不到的地方去。

> 组件不会告诉你它**现在**在哪 —— 这是故意的，告诉了就没有"找"这件事了。
> 它只告诉你"上次来是什么时候"，那是**证据链**，不是导航。

### 状态面板上那几个按钮现在的语义

- **喊它** / **碰 NFC 牌**：只让它走到你跟前，**不再换房间**。
  换房间要改写行程表，一改写，已经发出去的 timeline 就和新的对不上，唯一性立刻破。
- **跳到它下次挪窝**：时间机器跳到下一个边界，看它怎么走过去。
- **重置行程**：清空行程表重生成。**所有已放置的组件都会错位**到下次刷新才恢复，
  这是调试用的，别当功能用。

---

## 6. 卡住了怎么办

按这个顺序排查：

```bash
# 1. 先跑静态自检（不需要 Xcode，node 就行）
node Tools/_check.js

# 2. ★ 行程表 + 唯一性（最重要，改过 Schedule.swift 就必须跑）
node Tools/_schedule_check.js

# 3. 看动作循环的行为
node Tools/_sim.js

# 4. 想调参数，先跑扫描看清楚代价
node Tools/_tune.js
```

> ⚠️ **改了 `Schedule.build()` 里 `rnd()` 的调用次数，必须重跑 `_tune.js`。**
> 每多一次随机调用，整个随机序列就往后错一位，所有调好的参数全部作废。
> 已经踩过：把 `toIsland: Bool` 换成 `islandHours` 时多了一次 `rnd()`，
> 跨页率从 22.7% 悄悄跳到 30.9%，7 天开始漏组件——**不跑脚本根本发现不了**。

Xcode 里报错时，**先看第一条 error**——Swift 经常一个错带出几十条级联报错。
最常见的三类（`@main` 重复 / target membership / iOS 版本）上面都覆盖了。

---

## 7. 上架前还要做的事

这份代码是**能跑的原型**，不是能上架的产品。差在：

- [ ] **灵动岛的审核说明**：Apple 要求 Live Activity 只用于「有明确起止的进行中任务」。
      宠物状态是擦边，建议准备话术说明它的「进行中任务」是什么、有起止、可结束。
- [ ] **「选房间」这一步的引导**：每个组件都要用户长按 → 编辑 → 选房间，绕不过去。
      这一步不教，用户加完组件看到的是空的，会以为坏了。**这是上架前最该做的一件事。**
- [ ] **建议把「加满 16 个」做成 onboarding 的一环**：房间越多，找它越有味道。
      可以做成一张清单，勾一个加一个。
- [ ] **隐私政策**：虽然不读任何用户内容，声明里要写清楚，并在 App Privacy 里勾选"不收集数据"
- [ ] **NFC**：这版没接 CoreNFC。`nfcRecall()` 的调用点已留好，接上需要申请 NFC  entitlement
- [ ] **无障碍**：猫的位置变化目前只有视觉，VoiceOver 读不到
- [ ] **图标和启动页**：没做，先用系统默认的
