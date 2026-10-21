# Wireline 界面、动效与交互规范

> 适用范围：`Sources/Wireline` 下所有 SwiftUI / AppKit 界面。
> 代码落点：[`Sources/Wireline/Motion.swift`](../../Sources/Wireline/Motion.swift)（token、转场、按钮样式、hover、脉冲）。
> 参照：Apple HIG · Motion / Accessibility，以及 macOS 自带应用（Finder、系统设置、Spotlight、菜单）的实际表现。

改界面前先读一遍第 1、2 节；新增组件时对照第 4 节；提交前过一遍第 7 节的检查清单。

---

## 1. 原则

1. **动效是反馈，不是装饰。** 每个动画都要回答"它告诉用户什么"：这是可点的（hover）、我收到了（press）、东西从哪来到哪去（转场）、还在进行（脉冲）。答不上来就删掉。
2. **键盘操作不等动画。** 方向键移动高亮、回车执行、⌘数字切标签，结果必须在当前帧出现。动画只服务鼠标和状态变化。
3. **进场慢一点，离场快一点。** 进场用弹簧或 easeOut，让人看清它从哪来；离场用 easeIn 并且更短，别挡路。
4. **弹簧为主，不要弹跳。** 工具型应用的 bounce 不超过 0.2。会"Q 弹"的只有桌宠这种有意为之的角色元素。
5. **不要让终端逐帧重排，也不要让它硬切。** 会改变终端尺寸的布局变化一律走"冻结 → 动画 → 一次提交"。见第 3 节。
6. **尊重"减弱动态效果"。** 系统设置 → 辅助功能 → 显示 → 减弱动态效果打开时：位移和缩放改成短交叉淡化，循环动画全部停掉。
7. **和原生保持一致。** macOS 的按钮按下是变暗而不是缩小；菜单高亮是瞬时的；选中态不滑动；光标保持箭头（只有真正的超链接用手型）。

---

## 2. Motion Token

**按意图选 token，不按时长。** 代码里不允许出现裸的 `.easeInOut(duration:)`、`.spring(response:…)`，全部用 `Motion.xxx`。

| Token | 曲线 | 用在哪 |
|---|---|---|
| `Motion.hover` | easeOut 0.12s | 指针进出：底色、文字颜色、图标显隐 |
| `Motion.press` | easeOut 0.08s | 鼠标按下 |
| `Motion.release` | spring 0.26s, bounce 0.18 | 鼠标抬起回弹 |
| `Motion.state` | smooth 0.2s | 原地状态变化：鼠标选中、开关、连接状态变色 |
| `Motion.disclose` | spring 0.3s, bounce 0 | 展开 / 折叠：分组、箭头旋转、行内展开操作 |
| `Motion.popIn` | spring 0.22s, bounce 0 | 菜单、气泡、小卡片出现 |
| `Motion.popOut` | easeIn 0.12s | 上面这些消失 |
| `Motion.modalIn` | spring 0.3s, bounce 0.05 | ⌘K / ⌘P 这类模态卡片出现 |
| `Motion.modalOut` | easeIn 0.14s | 模态卡片消失 |
| `Motion.banner` | spring 0.36s, bounce 0.16 | 横幅、浮动条从边缘滑入 |
| `Motion.expand` | spring 0.34s, bounce 0.12 | 用户主动召唤的浮层展开（桌宠聊天） |
| `Motion.scroll` | smooth 0.25s | 程序触发的滚动（回到底部） |
| `Motion.fade` | easeInOut 0.15s | 减弱动态效果时代替一切位移 |
| `Motion.ambient(p)` | easeInOut p 秒，往返循环 | 呼吸、脉冲；减弱动态效果时返回 `nil` |

时长的上限：交互反馈 ≤ 0.12s，状态变化 ≤ 0.3s，转场 ≤ 0.4s。环境循环的周期 0.8–2.4s。

### 2.1 调用方式

```swift
wlAnimate(Motion.disclose) { collapsed.toggle() }   // 自动适配减弱动态效果
wlAnimateTerminalLayout { showAI = true }           // 会改终端尺寸的布局：冻结 → 动画 → 一次提交
.wlHover($hover)                                    // 代替 .onHover { hover = $0 }
.transition(.wlPop(anchor: .topLeading))            // 转场自带时序
.wlPulse(isConnecting)                              // 代替手写 repeatForever
```

`.transition(...)` 的转场已经自带进场 / 离场时序（`AnyTransition.animation`），调用方仍应把触发它的状态变化包进 `wlAnimate`，否则部分容器不会执行离场动画。

---

## 3. 布局变化与终端重排

终端（SwiftTerm）每次 `setFrameSize` 都会按新尺寸重排，并向远端发送 SIGWINCH 让 shell 重画提示符。所以**直接给终端做宽高动画**会逐帧重排、提示符反复重画；**直接瞬切**则表现为"闪一下、硬生效"。两种都不行。

正确做法是 **冻结 → 动画 → 一次提交**（`TerminalResizeGate`，见 `TerminalWindowView.swift`）：

1. 动画开始前冻结所有可见终端的网格尺寸：终端视图保持原尺寸，钉在左下角，被容器裁切或留白，提示符始终可见。
2. 周围布局正常做弹簧动画（侧栏、AI 面板、广播条）。
3. 动画结束时，每个终端只调整一次尺寸（只发一次 SIGWINCH），同时用旧画面快照做 0.14s 交叉淡化，把这唯一一次重排藏掉。

调用方式：`wlAnimateTerminalLayout { sidebarCollapsed.toggle() }`。减弱动态效果时会自动退化为瞬切。

| 变化 | 处理 |
|---|---|
| 侧栏（主机列表） | **悬浮抽屉，盖在终端上方**，终端尺寸永不改变，因此无需冻结。从左侧滑入（`Motion.expand`），带浅遮罩；左边缘悬停 0.18s、⌘S 或角落按钮打开，点外面、连接或（悬停打开时）指针离开则收起 |
| AI 面板开 / 关 | 默认**浮在终端上方**（从右侧滑入，不改终端尺寸）；用户点图钉固定后才成为一栏，开关和固定 / 取消固定都走 `wlAnimateTerminalLayout` |
| 全宽页面标题（工具页、主机详情、总览） | 统一用 `WLPageHeader`：顶部让出 28pt 标题栏，标题行与标签栏同高，从侧栏按钮右侧开始 |
| 广播条出现 | `wlAnimateTerminalLayout`，从顶部滑入 |
| 终端 ↔ 端口转发 / 文件 / 密钥 | 交叉淡化，两边都按最终尺寸挂载，终端不会中途改尺寸 |
| 终端搜索条、断线横幅、Vim 提示 | 浮在终端上方（overlay），可以完整做动画 |
| 侧栏分组展开 | `Motion.disclose` + `.wlDisclose` |
| 切换标签 | 瞬切（高频操作，等动画会拖慢） |
| 拖动窗口边缘改尺寸 | 实时重排，和 Terminal.app 一致（冻结只在程序触发的布局动画里生效） |

判断标准：**这个变化会不会改变 `TerminalHostView` 的 frame？** 会，就必须走 `wlAnimateTerminalLayout`。

### 3.1 与 shell 的配合（对标 Ghostty / kitty）

| 层 | Ghostty / kitty 的做法 | Wireline |
|---|---|---|
| 通知 PTY | Ghostty 把尺寸变化合并 25ms 再发 TIOCSWINSZ（`src/termio/Thread.zig`） | `ResizeDebouncer`：屏幕实时重排，尺寸稳定 120ms 后只发一次 SIGWINCH |
| 系统触发的尺寸连发（全屏、平铺） | 逐帧重排 | 冻结网格，稳定后重排一次 + 快照交叉淡化 |
| 提示符 | 依靠 OSC 133;A 标记，重排**之前**擦掉提示符，交给 shell 重画；`redraw=0` 不擦、`redraw=last` 只擦最后一行（kitty 首创，Ghostty 扩展了 `last`） | 同样做法：`blankPromptBeforeReflow` 只在本地擦除，不经过 PTY，光标留在原位 |
| 标记来源 | shell 集成自动注入 | 本地 zsh：Wireline 的 ZDOTDIR shim 自动输出 133;A / 133;C；远端：在服务器的 `~/.p10k.zsh` 里设 `POWERLEVEL9K_TERM_SHELL_INTEGRATION=true` |

原理（见 powerlevel10k README「Horrific mess when resizing terminal window」）：重排会改变"提示符起点到光标"之间的行数，而 zsh 收到 SIGWINCH 后按旧的行数回退擦除，于是在错误的位置重画，留下重复的提示符。先把这段区域清成空行，空行重排时不会变高，zsh 记住的行数就仍然正确。

**GPU 渲染（Metal）下的快照**：`cacheDisplay` 读不到 Metal 图层，所以 `WirelineTerminalView.snapshotImage()` 会在截图那一刻临时切回 CoreGraphics 画一帧再切回 Metal。截图只发生在冻结开始时，那时终端马上就被快照盖住，所以这一帧看不到。Metal 图层默认不透明，开启后必须设 `isOpaque = false`，否则壁纸透不过来。

远端没有输出 133 标记时，只能靠防抖把重复降到最多一次，无法彻底消除，这一点与 Ghostty、kitty 相同。

面板入场如果用 `.wlAppear`，必须写在面板 `.background(...)` **之前**，也就是只作用于内容。如果连半透明底色一起淡入，第一帧会露出没被压暗的壁纸，看起来像闪了一下（⌘S 展开侧栏时出现过）。

---

## 4. 组件规范

### 4.1 按钮

| 样式 | 什么时候用 | hover | 按下 | 禁用 |
|---|---|---|---|---|
| `.wlPlain` | 默认。文字按钮、`[方括号]` 按钮、自绘行 | 由 label 自己决定（变色） | 不透明度 0.6 | 不透明度 0.4 |
| `.wlIcon` | 工具栏、面板标题栏的纯图标按钮 | 6pt 圆角浅底 8% | 浅底 14% + 缩到 0.94 | 0.4 |
| `.wlPill(tint, prominent:)` | 主要操作：重新连接、发送、确认 | 底色加深 | 底色再加深 + 缩到 0.97 | 0.4 |

- 禁止再用 `.buttonStyle(.plain)`：它没有按下反馈。
- 图标按钮的可点区域不小于 24×24pt，即使图标只有 10pt。
- 危险操作（删除、断开、关闭）hover 时才显红色；平时保持弱化。

### 4.2 列表行（主机行、片段行、待办行）

- hover：底色 `surface` 30% 透明度，`Motion.hover` 淡入。
- 选中：底色 `surface` 55% + 左侧 2pt 强调色竖条，**选中切换不做滑动**，只做 `Motion.state` 淡入淡出。
- 激活主机下方的行内操作（端口转发、文件）用 `Motion.disclose` 展开，内容 `.wlDisclose`。
- 双击连接、单击选中；拖拽时的预览要和行本身同款字体颜色。

**卡片里的可点击列表**（片段、MCP 服务器、技能等）用 `WLListCard` + `.wlRowHighlight(hover:selected:)`：卡片内缩 4pt，行与行间隔 2pt、不画分隔线，hover 是内缩的 7pt 圆角浅色块。**不要**铺满整行的直角色块，它会盖住卡片的圆角，还会被上下分隔线夹住。行尾操作用图标按钮：主要操作（运行）常驻，编辑、删除只在 hover 时出现。

### 4.3 分组标题

- 箭头旋转与内容展开共用一次 `Motion.disclose`。
- 拖拽悬停为投放目标时，底色变强调色 18%，用 `Motion.hover` 过渡。
- 计数徽标数值变化时不跳动，用 `.contentTransition(.numericText())`。

### 4.4 右键菜单（`WLContextMenu`）

**用系统原生菜单（NSMenu），不自己画。** 毛玻璃材质、深浅色适配、弹出位置与屏幕边缘翻转、键盘导航、选中闪烁、子菜单全部由系统提供；自绘版本在浅色主题下又大又灰，交互也只是模仿。

- 调用方式不变：`.wlContextMenu([...])`、`.wlContextMenuBackground([...])`。
- 超过 4 个同类选项收进子菜单：`.submenu("移到分组", [...])`、`.submenu("颜色标识", [...])`；当前值用 `checked: true` 打勾，不要在标题里写 "✓"。
- 危险项 `destructive: true` 显示为红色标题，放在最后并用分隔线隔开。
- 支持右键与 Control-点击。

### 4.5 模态浮层（⌘K 快速连接、⌘P 命令面板）

- 遮罩：黑色 40%，`wlScrim` 淡入 0.2s / 淡出 0.14s，点击遮罩关闭。
- 卡片：`wlModal`，从上方 6pt、缩放 0.97 落位；关闭时缩到 0.98 并淡出。
- 打开的同一帧输入框获得焦点，不等动画结束。
- 高亮行随键盘**瞬移**；鼠标 hover 某行会把高亮移过去（与键盘共用一个高亮，避免出现两个高亮）。
- 列表为空时的提示文字用 `Motion.state` 淡入，不要闪烁。

### 4.6 横幅与浮动条

- 断线横幅、终端搜索条：`wlSlide(.top)`。
- 行内 AI 卡片（⌘;）：`wlSlide(.bottom)`。卡片内部"思考中 → 出命令"的切换用 `Motion.state`。
- 回到底部按钮：`wlPop(anchor: .bottom)`；滚动本身用 `Motion.scroll`。

### 4.7 标签栏

- 选中标签：底色与 2pt 下划线用 `Motion.state` 过渡；切换本身瞬时。
- 关闭按钮 `[x]`：平时 70% 弱化，hover 整个标签时提亮，hover 按钮本身变红。
- 运行中徽标、未读点：`wlBadge` 出现；运行中的点用 `.wlPulse`。

### 4.8 状态指示（连接点、状态栏）

- 连接中：琥珀色点 `.wlPulse(period: 0.7)`；已连接：绿色加 3pt 辉光；断开：红色。颜色切换 `Motion.state`。
- 状态栏底色随连接状态变化，同样 `Motion.state`。
- 数值（延迟、CPU、内存）用 `.contentTransition(.numericText())` 或等宽数字，避免文本宽度抖动。

### 4.9 桌宠

- 展开 / 收起：`Motion.expand`，从右下角锚点缩放。
- 呼吸、摇尾：`Motion.ambient`；眨眼不受影响但减弱动态效果时停掉。
- 悬停气泡：`Motion.hover`，位置始终占位，只改不透明度，避免精灵位移。

### 4.10 弹窗（Sheet）

所有 Sheet 一律用 `WLSheet`（`Controls.swift`），弹出和收起的动画交给 AppKit 系统 Sheet，不要自己再加。

```
┌──────────────────────────────────────────┐
│ [图标] 标题                          [×] │  头部：28pt 图标块 + 标题 + 一行副标题
│        副标题                            │
├──────────────────────────────────────────┤
│                                          │
│  分区标题                                │  内容：20pt 内边距，分区间距 18
│  ┌────────────────────────────────────┐  │
│  │ 标签                        [控件] │  │  WLFormSection 卡片
│  ├────────────────────────────────────┤  │  WLFormDivider 细分隔线
│  │ 标签                        [控件] │  │
│  └────────────────────────────────────┘  │
│  卡片下方的说明文字（footer）            │
│                                          │
├──────────────────────────────────────────┤
│ [次要操作]            [取消] [ 主操作 ]  │  底栏：surface 30% 底色
└──────────────────────────────────────────┘
```

- **底栏按钮**：次要或工具类操作靠左；取消（`.wlSecondary` + `.keyboardShortcut(.cancelAction)`）和主操作（`.wlPrimary` + `.keyboardShortcut(.defaultAction)`）靠右。主操作在条件不满足时禁用。危险操作用 `.wlDestructive`。
- 回车触发主操作，Esc 取消，右上角 × 与取消等价。
- `[方括号]` 按钮只用在内容区里的小型行内操作（如"[选择…]"），不放在底栏。

### 4.11 卡片与表单

- **不套框。** 卡片是低对比底色（`surface` 40%）加一圈 55% 透明度的细描边。卡片里的控件**不再画自己的描边**：分段控件只留凹槽底色，下拉菜单只在 hover 时出现强调色描边，输入框只在获得焦点时出现强调色描边。
- 行高 38pt：左边标签（可带一行灰色说明），右边控件。行与行之间用 `WLFormDivider`。
- 分区标题用灰色小号大写字（不用强调色），说明文字放在卡片**下方**作为注脚，不塞进卡片里。
- 开关行用 `.toggleStyle(.wlSwitch)`，整行都可以点；列表里的勾选用 `.wlCheckbox`。
- 由配置文件接管的控件用 `.wlConfigLocked("key")`：控件禁用，下方显示琥珀色的键名标签。

### 4.12 浅色主题

- 主题背景亮度大于 0.5 就视为浅色主题。此时 `WL.colorScheme` 为 `.light`，系统菜单、滚动条、颜色井会跟着变成浅色。所有窗口都写 `.preferredColorScheme(WL.colorScheme)`，不要写死 `.dark`。
- 浅色下 `accentBright` 是**加深**的强调色，不是加亮的；`surface` / `border` 的混合比例更小，否则会显得发灰发脏。
- 阴影和遮罩用 `WL.depth(深色下的不透明度)`，浅色下会自动减轻到约 45%。
- 禁止写死 `.white` / `.black` 作为文字或底色；AppKit 侧用 `NSColor.labelColor` 这类会随外观变化的颜色。
- 主题的光标色同时就是界面强调色，所以浅色主题要选饱和、够深的光标色。

---

## 5. 减弱动态效果

| 正常 | 减弱动态效果打开时 |
|---|---|
| 缩放、位移转场 | 0.15s 交叉淡化 |
| 弹簧 | `Motion.fade` |
| 按下缩放 | 只保留变暗 |
| 呼吸、脉冲、摇尾 | 静止 |
| 程序滚动 | 照常（滚动是功能，不是装饰），但用 `Motion.scroll` 而不是更长的曲线 |

全部由 `Motion.resolved` / `Motion.ambient` / 各转场内部判断，调用方不需要自己读系统设置。

---

## 6. 不要这样做

- ❌ `.onHover { hover = $0 }` —— 瞬变。用 `.wlHover($hover)`。
- ❌ `.buttonStyle(.plain)` —— 没有按下反馈。
- ❌ 写了 `.transition(...)` 却不包 `withAnimation` —— 转场不会执行。
- ❌ `withAnimation(...).repeatForever` —— 不受减弱动态效果约束。用 `.wlPulse` / `Motion.ambient`。
- ❌ 直接给侧栏、AI 栏、广播条做宽高动画，或者用 `wlSnap` 瞬切 —— 前者逐帧重排，后者硬闪。用 `wlAnimateTerminalLayout`。
- ❌ 键盘移动高亮时加动画 —— 拖慢键盘用户。
- ❌ 让带半透明底色的面板自己做淡入淡出或位移 —— 底色跟着变浅，或者滑动时留出缝隙，都会透出没压暗的壁纸，看起来像闪了一下。底色画在**不动的外层容器**上，只让内容动（侧栏抽屉就是这样做的）。
- ❌ 把可点的控件放进窗口顶部 52pt 的标题栏带却不加 `.blocksWindowDrag()` —— 隐藏标题栏后这一带仍是窗口拖动区，按下鼠标会被当成拖窗口，按钮收不到点击（`WLPageHeader` 已自带）。
- ❌ `NSCursor.pointingHand` 用在普通按钮上 —— macOS 只在链接上用手型。
- ❌ 离场比进场还慢。

---

## 7. 提交前检查清单

- [ ] 新代码里没有裸的 duration / spring 参数，全部是 `Motion.xxx`
- [ ] 没有新增 `.buttonStyle(.plain)` 和 `.onHover { hover = $0 }`
- [ ] 所有 `.transition` 的触发点都包了 `wlAnimate` 或 `withAnimation`
- [ ] 打开"减弱动态效果"走一遍：没有缩放 / 位移，没有循环动画
- [ ] 开关 AI 面板、折叠侧栏时终端里跑着 `htop` / `vim`，不花屏
- [ ] 纯键盘走一遍 ⌘K、⌘P、右键菜单：高亮瞬移，回车 / Esc 都能用
- [ ] 窗口缩到最小尺寸，右键菜单贴近右下角时不会溢出窗口
- [ ] 切到一个浅色主题（如 GitHub Light）走一遍：没有看不见的文字、发灰的卡片、过重的阴影
- [ ] 新增的 Sheet 用了 `WLSheet`，回车 / Esc 都能用
