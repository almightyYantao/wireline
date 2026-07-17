# MCP + 技能 冒烟测试包

零依赖地把 Wireline 的 **MCP 工具调用** 和 **运维技能** 端到端验一遍。
只需要 `python3`（macOS 自带）和一个已配置好的 AI endpoint。

`mock_mcp_server.py` 是一个本地 stdio MCP server，暴露三个工具：

| 工具 | 类型 | 说明 |
|---|---|---|
| `echo` | 只读 | 回显你给的文本 |
| `server_time` | 只读 | 返回当前时间 |
| `append_note` | **写操作** | 往 `/tmp/wireline-mcp-note.txt` 追加一行 |

`echo` / `server_time` 带 `readOnlyHint`，Wireline 直接调用不弹窗；
`append_note` 未标注 → 当作会改状态，**调用前会弹确认框**（用来验证确认流程 + “始终允许”）。

> 协议本身已单独验证过（`initialize` 握手 / `tools/list` / `tools/call` / 错误处理都正确）。
> 所以如果接进来后不工作，问题基本在客户端配置或模型输出格式，范围很小。

---

## 一、加服务器

1. 设置 → AI → **管理 MCP Server…** → 顶部勾选 **启用 MCP**。
2. **添加 Server**，传输选「本地 stdio」，填：
   - 名称：`mock`
   - 命令：`python3`
   - 参数：`/Users/admin/Desktop/Private/wireline/examples/mcp-smoke/mock_mcp_server.py`
     （换成你机器上的绝对路径）
3. 保存。状态应变成 **已连接 · 3 个工具**。若为「失败」，点「重新连接」，并确认 `python3` 在 PATH 里、路径正确。

## 二、验 MCP 调用（AI 面板）

打开终端旁的 ✨ AI 面板，**开启「自动执行」**，依次问：

| 你问 | 预期 |
|---|---|
| `用 echo 工具回显 hello` | 出现 `▶︎ 调用 MCP 工具：mock.echo`，随后回显 `hello`，**不弹窗**（只读） |
| `现在服务器几点？用 server_time` | 直接调用、返回时间，**不弹窗** |
| `用 append_note 记一条：smoke test` | **弹确认框**（mock.append_note + 参数）→ 点「调用」→ 执行后 `cat /tmp/wireline-mcp-note.txt` 能看到该行 |
| 再问一次 append_note | 若上一步点了「始终允许并调用」，这次应**不再弹窗** |

只读沙盒验证：在 设置 → AI 打开「只读沙盒」，再让它 `append_note` → 应被 **⛔ 拦截**，不执行。

## 三、验运维技能

技能靠模型按需载入。挑一台已保存主机连上（或用本地 shell），开「自动执行」，问：

| 你问 | 预期 |
|---|---|
| `这台机器负载有点高，帮我诊断下` | 出现 `📋 已载入技能：负载 / CPU 诊断`，随后 AI 按步骤跑 `uptime` / `top` / `free` 等只读命令并汇总 |
| `磁盘快满了，排查一下` | 载入「磁盘空间排查」，逐层 `df -h` / `du` 定位 |
| `看看有没有服务挂了` | 载入「服务健康检查」，`systemctl --failed` / `ss -tlnp` |

在**桌面宠物**里同样可用：`⌥⌘J` 唤出，问「把 IAI 组所有机器做个安全基线快检」→ 应载入 `security-baseline` 技能并用 plan 在整组只读执行。

## 四、排错

- **一直「连接中/失败」**：命令/路径不对，或 `python3` 不在 PATH。终端手动跑 `python3 <路径>` 应能启动（它会静默等待 stdin，`Ctrl-C` 退出）。
- **模型不调用工具/技能**：多为模型太弱或没走「自动执行」。换主模型、确认 Agent 模式开着；工具/技能清单会注入到 system prompt，可在会话里让它「列一下你能用的工具和技能」自查。
- **清理**：删掉这台 mock server；`rm /tmp/wireline-mcp-note.txt`。
