# wireline-agent：会话常驻进程设计

> 状态：P1–P3 已完成，P4 未开始（2026-10-24）。分支 `wireline-agent`。
> 相关代码：[`TerminalIO.swift`](../../Sources/Wireline/TerminalIO.swift)、[`PTYProcess.swift`](../../Sources/WirelineCore/PTYProcess.swift)、[`GhosttyIO.swift`](../../Sources/Wireline/Ghostty/GhosttyIO.swift)、[`SessionStore.swift`](../../Sources/Wireline/SessionStore.swift)。
> Ghostty fork：`~/Desktop/Private/ghostty-wireline`，分支 `wireline`。

## 1. 要解决的问题

现在 PTY 由 App 进程持有（`TerminalIO` → `PTYProcess`）。App 退出、升级、崩溃时，shell 和 ssh 都会被一起杀掉。下次打开时的「恢复」其实是：回放一份导出的带颜色文本，再重新连接。正在跑的命令、vim、Claude Code 会话都没了。

目标：**会话活得比 App 久**。

- 退出 App、升级重启以后，标签重新出现，并且就是原来那个进程：vim 还开着，`tail -f` 还在滚。
- 不改用 tmux 之类的复用器。字节流只解析一次（agent 里一次，界面里一次），也不会多出一层终端语义。

不在第一期做：远端常驻（agent 部署到服务器）、多台 Mac 同时接入、同一会话被多个窗口同时显示。

## 2. 总体结构

```
┌──────────── Wireline.app ────────────┐        ┌────────── wireline-agent ──────────┐
│ SessionStore / TerminalSession        │        │ SessionTable                        │
│ TerminalIO（ZMODEM、自动应答、日志、   │  Unix  │  ├─ Session 1: PTYProcess           │
│   忙闲判断…，照旧读原始字节流）        │ socket │  │    └─ libghostty-vt Terminal      │
│   └─ PTYBackend ──────────────────────┼────────┼─▶│      （无界面，权威状态）           │
│        ├─ LocalPTY（现在的 PTYProcess）│        │  ├─ Session 2 …                     │
│        └─ AgentPTY（经 socket）        │        │  └─ 终端应答（DA / DSR / OSC 颜色）  │
│ GhosttyTerminalView（manual IO）       │        └─────────────────────────────────────┘
│   └─ 接入时：io_restore(快照) → feed   │
└───────────────────────────────────────┘
```

- **agent 持有所有 PTY**。每个会话在 agent 里有一个无界面的 libghostty-vt `Terminal`，读到的每个字节都先喂给它，所以 agent 随时知道屏幕当前的权威状态。
- **App 只是客户端**。接入时先拿一份状态快照恢复界面，再接上实时字节流。`TerminalIO` 的所有功能（ZMODEM、密码和 sudo 自动应答、日志、忙闲、编辑器判断、`# …` 请求）照旧在 App 里读这条字节流，不用搬家。
- **`PTYBackend` 抽象**：`TerminalIO` 现在直接用 `PTYProcess`，改成通过一个协议使用后端。本地后端（`LocalPTY`）保持现在的行为，作为 agent 不可用时的退路。SwiftTerm 内核和 RDP 永远走本地后端。

## 3. 关键机制

### 3.1 接入时的状态同步（已验证可行）

10-22 的验证（`/tmp/wl-stateframe-spike`）结论：

- libghostty-vt 自带二进制快照编解码（`include/ghostty/vt/snapshot.h`）。顺序是 TERMINAL → SCREEN/PAGE → CONTINUATION → **READY** → HISTORY 页（从新到旧）→ FINISH。
- 6 段录制（zsh、vim、htop 等）逐格 100% 还原；切点落在 CSI 或 UTF-8 的半截也能正确还原，因为未完成的解析状态在 CONTINUATION 里。
- 性能：80×24 加 1 万行历史，READY 之前约 120 KB，编码 0.7 ms，READY 解码 0.13 ms。300×80 加 5 万行历史，总共 41 MB，但 READY 之前只有 197 KB。所以先送 READY 之前的部分，历史在后面慢慢补。
- 对照组（导出成 VT 序列再回放）会丢 OSC 133 提示符标记、软换行、标题、备用屏状态。所以 SwiftTerm 不走 agent。

接入流程，全部在该会话的串行队列上进行，所以天然不会丢字节、也不会重复：

1. 客户端发 `attach(session, grid)`。
2. agent 停止向这个客户端转发，在当前字节偏移 `N` 处编码快照：先发 READY 之前的部分。
3. agent 从偏移 `N` 开始实时转发字节流，每帧带上偏移量。
4. agent 在后台从新到旧发送 HISTORY 页，客户端把它们插到滚动缓冲的前面。
5. 收到 FINISH，同步完成。

每个输出帧都带 `offset`（PTY 输出的累计字节数）。客户端校验连续性；一旦对不上，就丢掉重新 attach。

### 3.2 终端应答只由 agent 回答

程序会向终端发查询（DA、DSR 光标位置、OSC 10/11 前景和背景色、CSI 14t 像素尺寸）。没有 App 接入时也必须有人回答，否则 vim 之类会卡住等回复。所以：

- **agent 永远回答查询**。界面相关的数值（主题颜色、字符像素尺寸）由客户端在 attach 和切换主题时告诉 agent；没人接入时用最后一次的值。
- **客户端 surface 产生的查询回复要丢掉**，只转发键盘、鼠标、粘贴、焦点这些真正的输入。这需要 fork 在 `io_write_cb` 里区分「回复」和「输入」，见 §5。

### 3.3 尺寸

只有一个客户端时，PTY 尺寸就是这个客户端的网格。现在 libghostty 在 `io_resize_cb` 里同步做 TIOCSWINSZ，保证重排和 SIGWINCH 对齐；改成发给 agent 后变成异步，中间隔着一跳 socket。处理方式：

- 客户端在 `io_resize_cb` 里立即发 `resize`（在 IO 线程上，不经主线程）。
- agent 收到后，同一队列上先 TIOCSWINSZ，再把尺寸同步给自己的 VT。
- 拖拽窗口时偶尔多一次提示符重画是能接受的；如果实测有明显的提示符错位，再考虑在 fork 里让 surface 等 agent 确认后再重排。

没人接入时保持最后的尺寸。

### 3.4 进程退出与重连

- 子进程退出后，agent 保留这个会话（处于「已退出」状态，带最终屏幕和退出码），等客户端来取，这样 App 能照常显示断线条和「重新连接」。
- 现在的「原地重连」（同一个视图、保留滚动缓冲）变成：让 agent 在**同一个会话**里重新 spawn。VT 不清空，界面照旧。
- 客户端确认看过的已退出会话，或者已退出超过 24 小时没人取的，agent 释放掉。

### 3.5 本地 shell 的忙闲判断

现在通过 PTY master 的 `tcgetpgrp` 判断前台进程。master fd 在 agent 手里，所以 agent 定时（0.8 s）检查，变化时推送 `foreground(job)` 事件；App 用它替代 `PTYProcess.foregroundJob()`。

### 3.6 agent 的生命周期

- **启动**：App 需要时自己拉起。`posix_spawn` 加 `setsid`，脱离 App 的进程组，App 退出后会被 launchd 收养。不走 `SMAppService` 和 LaunchAgent，因为不需要登录启动，也就不会出现「后台项目已添加」的系统提示。
- **单实例**：socket 路径加 `flock` 锁文件。
- **退出**：没有会话、也没有客户端超过 60 秒，自己退出。
- **崩溃**：会话全丢，App 退回现在的做法（回放滚动缓冲、重新连接）。所以本地的滚动缓冲存档继续保留，作为兜底。

### 3.7 升级

App 升级后，旧 agent 还在跑旧版本。

- 握手时交换协议版本和快照格式版本。协议的核心部分（spawn / attach / input / resize / exit）保持向后兼容。
- 快照格式 v1 官方不保证二进制兼容。如果版本对不上，就退回到「agent 导出 VT 序列」的有损同步：会丢 OSC 133 标记，但内容和光标都在。
- 新开的会话交给新版本 agent；旧 agent 服务完自己的会话后自然退出。第一期两个版本的 agent 可以同时存在，用不同的 socket 路径（`sessions-v<协议主版本>.sock`）。
- 以后再做：通过 SCM_RIGHTS 把 master fd 交接给新 agent。代价是新 agent 不是子进程的父进程，拿不到退出码，只能用 kqueue 的 `NOTE_EXIT` 知道它退出了。

### 3.8 安全（必须做，不是可选项）

spawn 请求里带着环境变量，包括 askpass 用的密码；socket 另一头还能往 `sudo -i` 之后的 root shell 里打字。所以只验证同一个用户是不够的：同一用户下的任何进程都能连上 socket，等于提权。

- socket 放在 `~/Library/Application Support/Wireline/sessions/`，目录权限 0700，socket 0600。
- 连上时先用 `getpeereid` 检查 uid，再用 `LOCAL_PEERTOKEN` 拿 audit token，通过 `SecCodeCopyGuestWithAttributes` 校验对方的代码签名：
  - Developer ID 签名（`bundle.sh` 的正常路径）：要求 Team ID 和签名标识符一致。
  - ad-hoc 签名（开发构建）：要求对方是同一个 App 包里的可执行文件，并且 cdhash 一致。
- 对方不合格就直接断开，并记日志。

### 3.9 文件与命名

| 项 | 位置 |
|---|---|
| 可执行文件 | `Wireline.app/Contents/MacOS/wireline-agent`，与 App 一起签名 |
| socket | `~/Library/Application Support/Wireline/sessions/sessions-v1.sock` |
| 锁 / 日志 | 同目录 `agent.lock`、`~/Library/Logs/Wireline/agent.log` |

注意：已有的 `Wireline/agent.sock` 是 Touch ID 的 ssh-agent（`SSHAgentController`），别和它混淆。代码里这个新进程统一叫 session agent。

## 4. 协议

帧格式：`u32 长度 | u8 类型 | payload`。控制消息的 payload 是 JSON，方便调试和兼容旧版本；数据帧（output、input、快照块）的 payload 是二进制。编解码放在 `WirelineCore`，可以单元测试。

| 方向 | 消息 | 说明 |
|---|---|---|
| C→A | `hello{proto, snapshotFormat, client}` | 握手；A 回 `hello{proto, snapshotFormat, agentVersion}` |
| C→A | `list` | A 回各会话的 `{id, kind, alias, title, cwd, state, exitCode?}` |
| C→A | `spawn{id, executable, args, env, cwd, execName, grid, cleanup[]}` | `cleanup`：会话结束时要删的临时文件（askpass 脚本） |
| C→A | `respawn{id, …}` | 已退出的会话原地重连 |
| C→A | `attach{id, grid, theme}` / `detach{id}` | 见 §3.1 |
| A→C | `snapshot{id, offset, chunk, phase: ready/history/finish}` | |
| A→C | `output{id, offset, bytes}` | |
| C→A | `input{id, bytes}` / `resize{id, grid}` / `theme{id, colors, cellPx}` | |
| A→C | `foreground{id, job}` / `exited{id, status}` | |
| C→A | `kill{id, signal}` / `release{id}` | 关闭标签：先 SIGHUP，再 SIGKILL，然后释放 |

## 5. fork 补的接口（P1，已完成 2026-10-24）

fork 分支 `wireline-agent`：`ca918cbaa`、`9b88d5b08`、构建脚本一次。只在本地，没有推送。

| 接口 | 用途 | 状态 |
|---|---|---|
| `build-ghosttykit.sh` 同时输出 `GhosttyVt/include` 和 `GhosttyVt/lib`（libghostty-vt，`ghostty_terminal_*`、`ghostty_snapshot_*`） | agent 用的无界面 VT | ✅ |
| `ghostty_surface_io_restore(surface, bytes, len)` | 用 READY 之前的快照原地替换 surface 的 terminal | ✅ |
| `ghostty_surface_io_restore_history(surface, bytes, len)` | 往前补历史；每块必须在 PAGE 记录后切开（`SnapshotFraming`） | ✅ |
| `ghostty_surface_io_set_replies(surface, bool)` | 客户端不回答查询 | ✅ |
| ~~agent 侧可设置应答用的颜色和像素尺寸~~ | 不需要改 fork：libghostty-vt 原生就有 `WRITE_PTY`、`SIZE`、`COLOR_*`、`DEVICE_ATTRIBUTES` 等选项 | — |

实现要点：

- restore 和 history 都走 manual backend 的输入队列，和 `io_feed` 的字节严格按顺序处理。所以可以先 restore，马上接着喂实时字节，历史在后面陆续补。
- 恢复时保留 surface 自己的尺寸、配置里的默认颜色和**滚动缓冲上限**。上限这一点是踩出来的：libghostty-vt 默认只保留 10 KB，恢复后第一段实时输出就会把补回来的历史整页淘汰。agent 的 VT 也改成 50 MB，和 Ghostty 的默认值一致；以后由 App 把用户的配置传过去。
- 恢复的历史会立即压缩。
- 验证：`SnapshotRestoreHarnessTests` 让两个真实的 surface 对比，一个直接喂全部字节，另一个恢复 agent 生成的快照、补历史、再喂剩下的字节，结果屏幕、滚动缓冲、视口逐字一致。覆盖了切点在转义序列中间、补历史前已经有实时输出、切点在备用屏里这几种情况。同时确认恢复的 surface 不回答查询。原有的 `GhosttyHarnessTests` 没有回归。

合回 main 之前要做：fork 推送并发新的预编译 Release，其中包含 GhosttyVt；然后更新 `fetch-ghosttykit.sh` 的固定版本和 sha256。现在这个分支只能用本地构建（`GHOSTTYKIT_SRC=…`）。

## 6. 分期

| 期 | 内容 | 验收 | 估计 |
|---|---|---|---|
| P1 fork | §5 全部 | ✅ 2026-10-24（`SnapshotRestoreHarnessTests`） | — |
| P2 agent | `wireline-agent` 可执行目标（复用 `PTYProcess`）、socket 服务、协议编解码、每会话 VT、快照、应答、前台进程、退出保留、单实例、空闲退出 | ✅ 2026-10-24（`AgentProtocolTests`、`AgentIntegrationTests`） | — |
| P3 App 接入 | `PTYBackend`（`PTYProcess` / `AgentPTY`）、`AgentClient`、attach 流程、`SessionSnapshot` 增加 `agentID` 和 `controlSocket`、启动时先接 agent 里还活着的会话、原地重连走 `respawn`、设置开关「会话常驻（实验）」默认关闭、⌥⌘Q、`bundle.sh` 打包 agent | ✅ 2026-10-24（`AgentSessionHarnessTests`：本地 shell 和 SSH 都能在「App 退出」后接回同一个进程；agent 不可用时退回本地 PTY）；还没在真实 App 里手测 | — |
| P4 收尾 | 代码签名校验、版本握手和新旧 agent 并存、agent 崩溃兜底、打包和签名、⌘Q 的交互、「结束所有后台会话」菜单 | 冒烟清单（升级、崩溃、未授权客户端被拒） | 3–4 天 |

合计约 3–4 周。每期结束合回分支里一个可运行的状态；设置开关打开之前，main 上的行为不变。

## 7. 已定的问题（2026-10-24）

1. **⌘Q**：打开「会话常驻」后，⌘Q 只关窗口，会话留在后台，下次打开原样接上。第一次退出时提示一次；菜单里加「退出并结束所有会话」（⌥⌘Q）。
2. **第一期覆盖**：本地 shell 和 SSH。快捷终端和交互式 `sftp` 会话放到以后；RDP 和 SwiftTerm 内核不走 agent。
3. **App 没开时保留多久**：可配置。设置里给一个时长（一直保留 / 1 小时 / 8 小时 / 24 小时），默认一直保留；超时的会话由 agent 发 SIGHUP。配置文件键 `session-agent-keep-alive`。
4. **没人接入期间的通知**（「命令完成」等）：第一期不做，因为判断逻辑在 App 里；以后可以让 agent 用 OSC 133 自己判断并发系统通知。

## 8. 风险

- **resize 多了一跳**（§3.3）：最可能出现在提示符重画上。P3 先实测，必要时让 fork 支持「等确认后再重排」。
- **快照格式 v1 不稳定**：上游一改格式，App 和 agent 的版本就必须匹配。所以有握手和 VT 退路（§3.7），fork 升级时也要 diff `snapshot.h`。
- **agent 里的 VT 和 App 里的 surface 状态分叉**：两边吃的是同一串字节，配置差异（比如 `scrollback-limit`）会让历史长度不同。agent 的配置以 App 传过去的为准。
- **安全校验做错了等于开了后门**（§3.8）：P4 要有一条专门的测试，确认用别的签名的进程连上来会被拒绝。

## 9. 实现记录（P2–P3）

- agent 用 `RunLoop.main` 驱动主线程，不能用 `dispatchMain()`：后者会让主线程退出，主队列改由别的线程执行，Swift 6 对 MainActor 的检查会直接崩溃。
- `AgentConnection` 释放时要先恢复被挂起的写端 DispatchSource，否则 libdispatch 会触发陷阱。
- App 端：agent 连不上时（3 秒内拉不起来），还没启动的会话改在 App 里运行（`AgentPTY.runsLocally`），所以打开终端永远不依赖 agent。
- 输出帧带偏移量；客户端发现偏移对不上，就重新 attach、拿一份新快照。
- 快捷终端不交给 agent（`allowsAgent: false`），因为它不存档，退出后接不回来。启动恢复时，agent 里没有标签对应的孤儿会话会被关掉。
- §3.8 已完成（`PeerIdentity`，两端都校验）：有 Team ID 时要求一致，ad-hoc 时要求同目录且签名有效。Debug 构建可以用 `WIRELINE_AGENT_TRUST_ANY=1` 放行（测试用），release 构建没有这个开关。已验证：xctest 被拒；同目录的 `wireline-agent probe` 被接受；正式包（Developer ID）里同一 Team 被接受、未签名的开发构建被拒。
- 待 P4：agent 升级时新旧版本并存的实测、首次 ⌘Q 的提示、真实 App 手测清单；fork 推送和含 GhosttyVt 的 Release（需确认）。
