# MCP 接入落地设计

> 目标:让 Wireline 的 AI 能调用用户安装的第三方 MCP server 工具(filesystem / github / postgres / k8s…),
> 并**保持模型无关**——不依赖 endpoint 的原生 function-calling,任何中转站 / 本地 Ollama 都能用。
> 这是"本地优先 · 数据主权 AI"护城河的自然延伸:工具从用户本机发起、密钥在 Keychain,
> 区别于 Warp(MCP 走其云端 agent)和 Termius(无 MCP)。

## 0. 设计原则:复用现有的"文本动作协议"

现状(已核对代码):

- `AIClient.stream(system:messages:model:)` 只发 `{model, messages:[{role,content}], stream}`,**不带** `tools` 字段。
- Agent "动手" = 文本约定:模型输出 ` ```bash ` 块 → `AIPanel.firstRunnableCommand` 提取 → 在会话里执行 → 输出回喂(`finishTurn` 循环,上限 `maxAgentSteps = 8`)。
- App 操作 = ` ```wl-action ` JSON 块 → `WLAction.parse` → `executeAction`,在 `systemPrompt()` 里向模型描述。
- 安全:`AICommandSafety.isDangerous/isReadOnly`、`AIRedactor.redact`、`pendingDanger` + `fetchDangerReview` 确认弹窗。

**MCP 不引入原生 function-calling,而是新增一个 wl-action 动词 `mcp_call`,沿用同一套解析/确认/回喂机制。** 这样零破坏地保住模型无关性。

---

## 1. MCP 客户端子系统(WirelineCore,新增)

纯 Swift、无 UI、可单测,和 `KeychainService` 同层。

```
MCPServerConfig        // 可持久化的 server 定义
  id: String
  name: String
  transport: .stdio(command: String, args: [String], envKeys: [String])   // envKeys 指向 Keychain 条目,不存明文
           | .http(url: String, headerKeys: [String])                     // Phase 2
  enabled: Bool

actor MCPClient        // 管一个 server 进程/连接
  - stdio: Process 拉起子进程,stdin/stdout 走 JSON-RPC 2.0(换行分隔)
  - handshake: initialize → 能力协商 → notifications/initialized
  - tools/list  → 缓存工具 schema(name, description, inputSchema, annotations)
  - tools/call {name, arguments} → 返回 content[]
  - 生命周期:enable / 启动时连,退出时 teardown;崩溃自动重连(带退避)

@MainActor @Observable MCPRegistry
  - servers: [MCPServerConfig] + 每个的连接状态
  - catalog: 聚合后的 [MCPTool]（server.tool 全限定名）
  - 供 systemPrompt 读工具清单、供 agent 循环路由调用
```

框架注意:MCP stdio 传输用**换行分隔的 JSON-RPC 2.0**;实现 `initialize` 能力协商,锁定一个目标协议版本(如 2025-06)。

---

## 2. 把工具暴露给模型(渐进披露,注入 systemPrompt)

在 `AIPanel.systemPrompt()` 末尾,当有启用的工具时追加一段(受数量/体积上限约束):

```
你还能调用外部工具(MCP)。需要时输出一个 ```wl-action 块:
{"action":"mcp_call","server":"github","tool":"search_issues","args":{...}}
可用工具:
- github.search_issues: 搜索 issue(参数: q, repo)
- postgres.query: 只读 SQL 查询(参数: sql)
- fs.read_file: 读文件(参数: path)
...
```

- **v1 只注入 名字 + 一句描述 + 参数名**,不塞完整 JSON schema(控 token)。
- 工具多时按上限截断(如前 40 个),并 `log`/提示"已省略 N 个"。
- Phase 2 做真正的渐进披露:模型先看清单,想用某工具时再按需注入它的完整 inputSchema。

---

## 3. 新动作 `mcp_call` + agent 循环集成

### 3.1 WLAction 扩展

`WLAction` 是 `Equatable`,`[String:Any]` 不满足 → **args 以 JSON 字符串存**:

```swift
case mcpCall(server: String, tool: String, argsJSON: String)
```

`WLAction.parse` 里加 `case "mcp_call":` 分支,把 `obj["args"]` 重新序列化成字符串保存。

### 3.2 执行路径(关键:走 agent 循环,不只是确认卡片)

其它 wl-action 是一次性、卡片确认;`mcp_call` 要像 bash 命令一样**执行→回喂→继续**。在 `finishTurn` 里,`firstRunnableCommand` 之后加一档:

```
若无 bash 命令,但解析出 mcp_call:
  - 只读沙盒(agentReadOnly)且该工具非只读 → refuseSandbox 同款拦截
  - 该工具是 mutating(见 3.3)→ pendingDanger 同款确认弹窗(展示 server.tool + args)
  - 否则 → 调 MCPRegistry.call(...) → 结果 redact 后:
      messages.append(.system, "▶︎ github.search_issues → …")
      modelMessages.append(.user, <工具结果>)
      startTurn()   // 继续,受 maxAgentSteps 约束
```

### 3.3 安全闸门(复用现有文化)

- **只读判定**:优先读 MCP 工具的 `annotations.readOnlyHint` / `destructiveHint`;缺失则**保守当 mutating**→需确认。
- **只读沙盒**:`agentReadOnly` 开启时,非只读工具直接拦(镜像 `refuseSandbox`)。
- **确认弹窗**:复用 `pendingDanger`/ActionCard 模式,展示 `server.tool` 和参数;可加"本工具以后允许"。
- **脱敏**:工具**结果**回喂前过 `AIRedactor.redact`(受 `ai.redact` 控制)——结果里最可能带密钥。
- **进程安全**:只允许用户显式配置的 server(不自动安装);UI 明示将要拉起的完整命令。

---

## 4. 密钥 & 设置

- MCP server 的 env(API key 等)存 **Keychain**(`KeychainService`),config 里只存 `envKeys` 引用;拉起子进程时注入到其环境变量。
- **设置 → AI → MCP** 新面板:增删改 server(名字/传输/命令或 URL/env→Keychain)、启用开关、连接状态 + 工具数、"测试连接"按钮。

---

## 5. Fleet + MCP(护城河兑现点)

- v1:MCP 调用是**全局 agent 能力**(本机发起),先只在主 AI 面板(`AIPanel`)可用。
- v2:让**舰队 agent**(`FleetRunner` + `PetChatView` 的 `PetPlan.parse` 循环)也能调 MCP。
  典型场景:"把所有 IAI 主机的磁盘占用汇总,并在 github 开一个 issue" = shell(fleet 并发)+ MCP(github)串起来——这正是纯 AI 终端给不了的组合。
  ⚠️ 注意 `PetChatView` 有独立的 plan 循环,MCP 支持要在那边也镜像一份。

---

## 6. 分期

| 阶段 | 内容 | 估量 |
|---|---|---|
| **P1 (MVP)** | stdio 传输;MCPClient + Registry;设置面板(手配 + Keychain);systemPrompt 工具清单;`mcp_call` 动作;agent 循环执行 + 确认 + 只读沙盒 + 结果脱敏;仅 `AIPanel` | ~2–3 天 |
| **P2** | HTTP/SSE 传输;基于 annotations 的只读自动分类;按工具"始终允许";PetChat + Fleet agent 支持 MCP;大结果截断/摘要 | — |
| **P3(可选)** | 为支持 function-calling 的模型加**可选**原生 `tools` 模式(多工具单轮更干净),文本约定仍作默认/兜底,**不砍模型无关性** | — |

---

## 7. 待定决策(需要你拍板的点)

1. **协议版本**:锁 MCP 哪个 spec 版本(建议最新稳定)。
2. **工具清单上限**:注入多少个 / 单结果截断阈值(默认 40 个 / 结果 4KB,和现有 `contextOutput` 的 4000 对齐)。
3. **默认确认策略**:mutating 工具是否"每次确认",还是允许"本会话内记住允许"。
4. **P1 范围**:是否 stdio-only 就够验证价值(建议是),SSE 放 P2。
