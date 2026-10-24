# 对外开放 MCP + 可还原脱敏 设计

> 状态：§9 已拍板（2026-10-24，全部按建议）；P1 已实现（分支 `privacy-masker`）。
> 参考：Netcatty（GPL-3.0，只借思路不搬代码）的 `electron/mcp/`、`docs/features/external-mcp-privacy.md`。

## 0. 目标与非目标

**目标**

1. **对外开放 MCP**：Claude Code、Codex、Cursor 等外部 Agent 能通过 MCP 调用 Wireline 的能力：看当前会话、读输出、在会话里执行、**按别名或分组批量执行（Fleet）**、读写远程文件、开连接。外部 AI 也能用上 Wireline 的主机关系，这是普通终端 MCP 给不了的。
2. **可还原脱敏**：发给模型的密码、token、真实地址先换成占位符；模型回传的命令或文件内容带着占位符时，本地先还原再执行。同一套机制同时替换内置 AI 现在的单向 `AIRedactor`。

**非目标（v1 不做）**

- 不开放 HTTP / 局域网传输（Netcatty 有 Streamable HTTP 监听 0.0.0.0，风险大、收益小），只走本机 stdio。
- 不改内置 AI 的"文本动作协议"（`wl-action`），也不引入原生 function calling。
- 不做"全系统 AI 流量过滤"：外部 Agent 自己的工具（本地 shell、读文件）不在保护范围内，文档里写清楚。

---

## 1. 总体结构

```
Claude Code / Codex ──stdio(JSON-RPC 行)──▶ wireline-mcp（垫片，Contents/MacOS/）
                                              │  原样转发 MCP 帧
                                              ▼  Unix socket ~/Library/Application Support/Wireline/mcp/mcp-v1.sock
                                         Wireline.app ── MCPServerHost
                                              ├─ 每个连接一个 MCPConnection（客户端信息、脱敏作用域、已加载工具集）
                                              ├─ MCPToolCatalog（工具定义 + 处理）
                                              ├─ PrivacyMasker（还原 → 校验 → 审批 → 执行 → 脱敏）
                                              └─ MCPApprovalCenter（刘海岛 / 弹窗 / 审计日志）
```

**为什么用垫片 + socket，不用 Netcatty 的 TCP 端口 + token 发现文件：**

- 所有逻辑（工具、脱敏、审批）都在 App 里，垫片只做转发（约 150 行），升级时只换 App 内的逻辑。
- Unix socket 不监听网络端口，不需要往磁盘写 token；连接时用现成的 `PeerIdentity.check(fd:)` 校验对方是同一 Team ID 签名的 `wireline-mcp`（会话常驻 agent 已经这样做了）。
- **一个 socket 连接就是一个 MCP 会话**，脱敏作用域、审批里"本次连接不再询问"的范围都自然绑定在连接上。

**垫片行为**

- 启动后连接 socket。连不上时，用 `open -gj -b <bundle id>` 在后台拉起 App，最多等 15 秒（见 §9 问题 2）。
- 连上后先发 `{"wl":"hello","v":1,"pid":…}`，App 回 `ok` 或拒绝原因（未开启对外 MCP、版本不匹配），然后双向逐行转发。
- App 未开启对外 MCP 时，垫片照常完成 `initialize`，`tools/list` 只返回一个 `wireline_status` 工具，调用时说明"请在 Wireline 设置 → AI → 对外开放 中开启"。这样外部 Agent 能把原因告诉用户，不会只报一句"server 启动失败"。
- socket 路径沿用 `sessions/sessions-v1.sock` 的做法，路径超过 `sun_path` 长度时退回短路径（`SSHAgentController.socketPath()` 已有这个逻辑）。

---

## 2. 工具清单（渐进加载）

MCP 客户端会自动给工具名加上 server 名做命名空间（`mcp__wireline__fleet_run`），所以工具名不加前缀。

### 2.1 一开始就暴露的核心工具（10 个）

| 工具 | 作用 | 实现复用 | 读/写 |
|---|---|---|---|
| `get_environment` | 当前打开的会话（id、别名、类型、cwd、是否忙、前台程序、连接状态）、聚焦的会话、分组列表、权限模式、脱敏是否开启 | `SessionStore.sessions` | 读 |
| `hosts_list(query?, group?)` | 主机：别名、分组、描述、用户、在线状态、主机画像摘要 | `HostStore`、`HostMemoryStore` | 读 |
| `session_read(session_id, lines=200)` | 会话最近输出（去掉 ANSI） | `TerminalSession.recentOutput` | 读 |
| `session_exec(session_id, command, visible?, timeout?)` | 在会话里执行并取回输出。`visible=true` 时在终端里打字执行（用户看得到），否则走 ControlMaster 在后台执行 | `runInTerminalCapturing` / `runCapturing` | 视命令而定 |
| `fleet_run(targets, command, timeout?, max_concurrent?)` | `targets` 可以写别名，也可以写 `@分组`；不用先连接，并发执行，返回每台主机的退出码和输出（逐台截断） | `FleetRunner.run` | 视命令而定 |
| `host_open(alias, split?)` | 打开一个 SSH 会话，等连上后返回 `session_id` | `SessionStore.open` / `splitHost` | 写（低风险） |
| `file_read(alias, path, max_bytes?)` | 读远程文件，同时返回 sha256 | `SFTPService` | 读 |
| `file_write(alias, path, content, expected_sha256?)` | 写远程文件。审批框里用现有的变更评审界面显示 diff；sha 不匹配就拒绝，防止覆盖别人刚改过的文件 | `AIFileEditView` 的评审 | 写 |
| `session_close(session_id)` | 只能关闭本连接打开的会话 | `SessionStore.close` | 写 |
| `load_tools(toolset)` | 加载下面的扩展工具集，并发送 `notifications/tools/list_changed` | — | — |

### 2.2 按需加载的工具集

| toolset | 工具 |
|---|---|
| `files` | `file_list`、`file_stat`、`file_mkdir`、`file_rename`、`file_delete`、`file_upload`、`file_download`（本机 ↔ 远程，复用 `FleetRunner.upload/download`） |
| `jobs` | `exec_start` → `exec_poll(job_id, since)` → `exec_stop`，用于长时间运行或持续输出的命令（`tail -f`、构建） |
| `forwards` | `forward_list`、`forward_create`、`forward_start`、`forward_stop`（`ForwardStore`） |
| `snippets` | `snippet_list`、`snippet_run`（参数填好后按 `session_exec` 的规则执行） |
| `hosts_admin` | `host_add`、`host_update`、`group_list`、`host_memory_get/set`，直接写 `~/.ssh/config` |
| `all` | 以上全部 |

不支持 `list_changed` 的客户端，`load_tools` 的返回里会附上新工具的完整 schema，并提示用 `call_loaded_tool(name, args)` 这个通用入口调用。这是兜底，只在这种客户端上出现。

### 2.3 server instructions（`initialize` 的返回）

一段很短的说明，告诉模型怎么用：

> Use Wireline for anything on the user's SSH hosts. Call `get_environment` first. Address hosts by their `~/.ssh/config` alias or `@group`; prefer `fleet_run` for more than one host. Never run ssh from the local shell for these hosts. Values like `[WL…_IP_3]` are masked placeholders: pass them back verbatim, never guess the real value. Denials are final; do not work around them.

另外在设置页提供"安装 Claude Code skill"按钮（可选），写入 `~/.claude/skills/wireline/SKILL.md`，内容和上面相同，再补几条示例。

---

## 3. 权限与审批

### 3.1 三档模式（设置 → AI → 对外开放）

| 模式 | 读工具 | 只读命令（`AICommandSafety.isReadOnly`） | 其他写操作 / 命令 | 危险命令（`isDangerous`） |
|---|---|---|---|---|
| 只读 | 放行 | 放行 | **拒绝** | 拒绝 |
| 确认（默认） | 放行 | 放行 | **逐次审批** | 审批 + AI 影响评估 |
| 信任 | 放行 | 放行 | 放行 | **仍需审批** |

另外几条规则不随模式变化：

- `fleet_run` 的目标超过 5 台时，只要不是只读命令就一定要审批。
- `hosts_admin`（会改 `~/.ssh/config`）一定要审批。
- 判断读写、是否危险、审批内容，都基于**还原后的真实命令**（见 §4.3），否则模型可以把 `rm -rf` 的目标藏在占位符后面。

### 3.2 审批界面

- App 在前台时弹窗；在后台时刘海岛亮起并发系统通知，点击后弹窗。
- 弹窗内容：发起方（`initialize` 里的 `clientInfo.name`，例如 "claude-code"）、目标主机或会话、**真实命令**、危险命令附带 AI 影响评估（复用 `fetchDangerReview`）、`file_write` 显示 diff。
- 按钮：拒绝 / 允许一次 / **本连接内相同命令不再询问**。
- 120 秒没人处理就按拒绝算，返回给模型的错误写明"用户未批准"。
- 外部连接打开的会话，标签上加一个小角标显示来源（例如 Claude 图标），用户能看出哪些标签是外部 AI 开的。

### 3.3 审计日志

- 每次工具调用追加一行到 `~/Library/Application Support/Wireline/mcp-audit.jsonl`：时间、客户端名、工具、目标、**真实命令**、审批结果、退出码。这个文件只在本机，存真实值。
- 设置页能查看最近 200 条，也能一键在访达中显示。

---

## 4. 可还原脱敏（PrivacyMasker）

### 4.1 放在哪里

`WirelineCore/PrivacyMasker.swift`：纯 Swift，不依赖 UI，可以单测。对外接口：

```swift
public final class PrivacyMasker: @unchecked Sendable {   // 内部加锁
    public struct Policy: Codable, Equatable, Sendable {
        public var secrets: Bool          // 密码 / token / 私钥 / 长随机串
        public var addresses: Bool        // IP、真实主机名
        public var knownHosts: [String]   // 从 ssh config 取出的 HostName / IP，必定脱敏
        public var cidrs: [String]        // 额外要脱敏的网段
        public var patterns: [String]     // 用户自定义正则（编译失败 → 设置页报错，不会静默关掉）
    }
    public init(policy: Policy)
    public func mask(_ text: String) -> String                 // 发给模型之前
    public func unmask(_ text: String) throws -> String        // 模型回传之后；未知占位符 → 抛错
    public func display(_ text: String) -> String              // 给用户看（还原，但不报错）
}
```

### 4.2 占位符格式

`[WL<nonce4>_<类别>_<序号>]`，例如 `[WLk3f9_IP_2]`、`[WLk3f9_HOST_1]`、`[WLk3f9_SECRET_4]`。

- 每个作用域生成一个随机 nonce，**其他会话的占位符不会被误还原**，会直接报错。
- 不用 `«…»`，因为 `AICommandSafety.unfilledPlaceholder` 用这种写法表示"没填的参数"，会把命令拦下来。
- 同一个作用域里，同一个值永远对应同一个占位符，模型可以拿它做比较和关联（"这两台机器连的是同一个 DB"）。
- 映射只放内存：外部 MCP 一个连接一份，内置 AI 一个会话一份。不落盘，不跨会话共享。上限 1 万条或 8 MB，超出后报错，要求重新连接。

### 4.3 要识别的内容

| 类别 | 规则 |
|---|---|
| SECRET | 沿用 `AIRedactor` 的 `key=value` 和长 hex / base64，另外加：`-----BEGIN … PRIVATE KEY-----` 整块、`Authorization: Bearer …`、JWT（`eyJ…\.…\.…`）、URL 里的 `user:pass@`、常见云厂商密钥前缀（`AKIA`、`ghp_`、`sk-`、`xox[bp]-`），以及 **Keychain 里这台主机保存的密码**（按原值精确匹配，最可靠） |
| IP | IPv4 / IPv6。默认只处理私网段加用户配置的网段；可选"全部 IP" |
| HOST | ssh config 里的 `HostName`（真实域名和 IP）。**别名本身不脱敏**：别名就是天然的化名，模型靠别名指定主机，用户也认得 |
| 自定义 | 用户自己写的正则 |

**`key=value` 只替换 value**，变成 `password=[WLk3f9_SECRET_1]`，保留结构，模型仍能看懂这是个密码字段。

### 4.4 数据流（外部 MCP 和内置 AI 共用）

```
模型 → 工具参数 / 命令 / 文件内容
   → unmask（遇到未知占位符直接拒绝，不会发到主机）
   → 只读 / 危险判断、审批弹窗（显示真实值）
   → 执行
   → 输出 / 错误信息 / 主机列表 → mask → 模型
```

- 结构化结果按 JSON 逐个字符串处理，不在序列化后的文本上做替换。字段名是 `password`、`token`、`hostname` 这类的，值直接整体当成对应类别。
- 错误信息也要脱敏（ssh 报错里常带 IP）。

### 4.5 最直接的收益：AI 改文件不会再弄丢密码

现在 SFTP 的"AI 改文件"把文件**原样**发给模型（`AIFileEditView` 和 `RemoteEditStore` 都没有脱敏）。如果加上单向脱敏，写回时又会把密码变成 `«redacted»`。改成可还原以后：模型读到的是 `db_password=[WL…_SECRET_1]`，只改别的行，写回前占位符还原成原密码，文件完好，而密码从头到尾没离开本机。外部 MCP 的 `file_read` / `file_write` 也是同样的流程。

### 4.6 内置 AI：统一在 AIClient 这一层做（P1 已实现）

实际做法和最初的"逐处替换"不同：脱敏放在 `AIClient.stream`，所有 AI 功能都经过这里。

- 发出的 system 和每条消息都先 `mask`；有 masker 时在 system 末尾追加一段占位符说明（`AIClient.placeholderNote`）。
- 回复用 `StreamRestorer` 边流式返回边还原，拆成多段的占位符也能接上。调用方拿到的都是真实值，所以解析命令、界面显示、AI 改文件写回都不用再单独处理。
- 对话类（AI 面板按主机分、桌面宠物）用 `PrivacyContext.masker(conversation:level:)` 拿常驻的 masker，同一个值跨轮次保持同一个占位符；一次性调用（危险评估、Fleet 汇总、AI 改文件、内联 AI）每次请求新建一个。
- 主机的真实地址来自 `HostStore.hosts`（didSet 同步过去）；Keychain 里保存的密码按原值脱敏，最多一分钟重读一次。
- `AIChatStore.save` 落盘时把模型那一侧再脱敏一遍。重启 App 后，旧占位符就还原不了了：Agent 自动执行前会检查（AI 面板、桌面宠物），带旧占位符的命令或动作不执行，并告诉模型去重新读取；代码块的"运行"按钮也会变灰。
- `AIRedactor` 已删除。设置从开关改成三档 `ai-privacy = off | secrets | all`（默认 `secrets`），旧的 `ai-redact` 仍然可用。

### 4.7 已知限制（写进设置页说明）

- 模型没法对脱敏后的地址做计算，例如"同一个 /24 下的其他机器"。需要这种能力时可以对单个连接关掉地址脱敏。
- 模型可能自己拼出真实值（例如从 DNS 输出里拼出来），这种情况拦不住。脱敏能减少泄露，不能保证完全不泄露。
- 外部 Agent 自己的工具（本地 shell、读本地文件）不受保护。

---

## 5. 代码落点

| 位置 | 新增 / 改动 |
|---|---|
| `Sources/WirelineCore/PrivacyMasker.swift` | 新增，带单测 `PrivacyMaskerTests` |
| `Sources/WirelineCore/MCPWire.swift` | JSON-RPC 帧类型、按行分帧、hello 握手（和现有 `MCPClient` 共用编解码） |
| `Sources/WirelineMCP/main.swift` | 新的可执行 target `wireline-mcp`（垫片） |
| `Sources/Wireline/MCPServerHost.swift` | socket 监听、`PeerIdentity` 校验、为每个连接建 `MCPConnection` |
| `Sources/Wireline/MCPToolCatalog.swift` | 工具定义与处理、工具集 |
| `Sources/Wireline/MCPApprovalCenter.swift` | 审批队列、弹窗、刘海岛接入、审计日志 |
| `Sources/Wireline/MCPSettingsView.swift` | 加"对外开放"区：开关、模式、一键添加到 Claude Code / Codex、复制其他客户端的 JSON、审计日志 |
| `Sources/Wireline/AIClient.swift` 等 | `AIRedactor` 改为调用 `PrivacyMasker` 的薄封装，然后逐处替换 |
| `scripts/bundle.sh` | 把 `wireline-mcp` 拷到 `Contents/MacOS/` 并签名（和 `wireline-agent` 一样处理） |
| `Package.swift` | 加 `WirelineMCP` 可执行 target 和 product |

**一键添加**

- Claude Code：执行 `claude mcp add --scope user wireline -- "/Applications/Wireline.app/Contents/MacOS/wireline-mcp"`，先检查 `claude` 在不在 PATH 里。
- Codex：往 `~/.codex/config.toml` 追加 `[mcp_servers.wireline]`，写入前备份，已存在就跳过。
- 其他客户端：显示通用的 JSON 片段，带复制按钮。
- 写的都是用户自己的配置文件，所以每次都要用户点按钮确认，不会自动写。

---

## 6. 测试

- `PrivacyMaskerTests`：每个类别的识别；mask 后再 unmask 能还原；同值同占位符；未知 nonce 或序号会报错；占位符被截断时报错；超过上限报错；`key=value` 结构保留；私钥整块替换；`AICommandSafety` 在还原后才判断（用例：`rm -rf [WL…_SECRET_1]` 必须先还原再被识别成危险命令）。
- `MCPServerTests`（WirelineCore 层，用 socketpair）：握手、未开启时的 `wireline_status`、`load_tools` 和 `list_changed`、未知工具、参数校验。
- 集成测试：用真的 `wireline-mcp` 进程，配合 `WIRELINE_AGENT_TRUST_ANY` 跑一遍 initialize → `tools/list` → `hosts_list`。
- 手测：Claude Code 实际接入；用 Docker 容器 `wl-xrdp`（127.0.0.1:12222）跑 `fleet_run`、`file_write` 的审批和 diff，以及占位符往返还原。

---

## 7. 分阶段

| 阶段 | 内容 | 估时 |
|---|---|---|
| P1 | `PrivacyMasker` 加单测；内置 AI 全部替换（含 AI 改文件开启脱敏）；设置改成三档 | 2–3 天 |
| P2 | 垫片、socket、握手、只读工具（`get_environment`、`hosts_list`、`session_read`、`file_read`）、设置开关、一键添加到 Claude Code / Codex | 3–4 天 |
| P3 | 执行类工具（`session_exec`、`fleet_run`、`host_open`、`file_write`）、审批中心、刘海岛、审计日志 | 3–4 天 |
| P4 | 扩展工具集（files、jobs、forwards、snippets、hosts_admin）、server instructions、skill 安装、README | 2–3 天 |

合计约 2–2.5 周。P1 单独就有价值（内置 AI 立刻受益），可以先做先发。

---

## 8. 风险

- **同用户下的其他本地进程**：它们也能执行 `wireline-mcp`，从而接入 Wireline。这属于信任边界之内（同一用户），真正的闸门是"默认关闭的开关 + 逐次审批 + 审计日志"。设置页写明这一点。
- **审批疲劳**：模型连续发很多只读命令时不该打扰用户，所以只读命令自动放行。`isReadOnly` 的白名单要看得严：`curl`、`sed` 在列表里，`curl -X POST`、`sed -i` 都会改东西，P3 要把这两个收紧。
- **`list_changed` 兼容性**：各客户端支持程度不一，靠 §2.2 的兜底入口。

---

## 9. 已拍板（2026-10-24）

1. 外部 AI 在会话里执行命令，默认在终端里可见地执行（`visible=true`）；后台执行留给 `fleet_run` 和 `jobs`。
2. App 没开时，垫片自动在后台拉起 App。
3. 地址脱敏默认关闭，默认档位是 `secrets`。
4. 提供"信任"档，但危险命令和改 `~/.ssh/config` 在任何档位都要审批。
