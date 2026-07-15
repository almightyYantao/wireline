<p align="center">
  <img src="docs/banner.svg" alt="Wireline" width="860">
</p>

<p align="center">
  <a href="README.md">English</a> · <b>简体中文</b>
  &nbsp;·&nbsp;
  <a href="https://github.com/almightyYantao/wireline/releases/latest">下载</a>
  &nbsp;·&nbsp;
  <a href="https://almightyyantao.github.io/wireline/">官网</a>
</p>

> 原生 macOS SSH 客户端 · 内置 AI 副驾

Wireline 把命令行时代验证过的高效范式（别名、分组、批量、安全存储）做成一款原生 macOS 客户端，并在其上叠加了一个真正能**动手**的 AI 助手：自然语言生成/执行命令、诊断报错、跨主机群跑、甚至直接帮你建隧道/加主机。

主机数据**始终以标准 `~/.ssh/config` 为唯一数据源**——图形界面只是这份标准配置之上的高效外壳。卸载 Wireline 后，`ssh` / `scp` / `rsync` / VS Code Remote 仍能直接读取同一份配置，绝不锁定。

界面走终端黑客风（等宽字体 · 绿黑配色 · 可换主题），内置真实 PTY 终端、可视化 SFTP、图形化端口转发，以及整窗动态壁纸。

## 📸 截图

<p align="center">
  <video src="https://github.com/almightyYantao/wireline/raw/main/docs/ai-demo.mp4" controls muted width="90%"></video>
</p>

<p align="center"><img src="docs/image/wallpaper.png" width="90%" alt="整窗壁纸与主题"></p>
<p align="center"><img src="docs/image/files.png" width="90%" alt="双栏 SFTP 文件管理"></p>

---

## 🤖 AI 助手（特色）

设置 → AI 里填入 **OpenAI 兼容的服务地址 + Key**（中转站/直连），或指向本地 **Ollama**（数据不出本机）。终端右下角的 ✨ 打开 AI 面板。

- **自然语言 → 命令**：说需求，生成命令,`[插入]` 或 `[运行]`，绝不自动执行
- **命令栏 ⌘;**：说需求 → 生成命令 → 再按 ⌘; 执行
- **诊断报错 / 解释 / 总结**：一键分析终端输出、解释命令(高危警告)、总结长日志
- **Agent 自动执行**：AI 给命令 → 真实执行 → 拿输出 → 继续，直到给出结论
  - 可选**终端内执行(全程可见)**或**旁路执行**；**高危命令强制二次确认**；**只读沙盒**彻底禁写
- **舰队群跑**：多选主机 → 一句话 → 并发执行 → AI 汇总成结论/表格
- **AI 副驾**：一句话让 AI 操作客户端本身——建端口转发、加主机、连接、开文件、跑片段(均需确认)
- **SFTP 里 AI 改文件**：右键远程文件 → 说改动 → 预览 → **变更评审(影响+风险)** → 写回
- **变更评审**：危险命令执行前，AI 给出影响面与风险点再确认
- **主机记忆/画像**：AI 记住每台机器的稳定信息，之后回答自动结合，越用越懂你的环境
- **会话复盘 → Runbook**：把本次操作整理成带步骤/命令/回滚的 Markdown 手册
- **告警自动归因**：主机掉线时 AI 给出可能原因与排查建议(附在通知里)
- **上下文引用**：`@输出` / `@主机` / `@历史`（命令历史语义召回）
- **每主机独立会话历史**（持久化）、**token 用量估算**、**主/快速模型切换**、**发送前脱敏**、**存为脚本片段**

---

## ✨ 功能

**连接与管理**
- 🔍 全局快捷连接（⌘K）：Spotlight 式模糊搜索别名/描述/分组，回车即连
- 🗂 侧栏合并主机列表：分组分区、可折叠(状态记忆)、拖拽入组、右键新建/删除分组
- 🟢 连通性探测：`在线 / 离线 / 探测中`，已连接主机显示 `已连接`；可选后台巡检 + 系统通知
- 🔑 认证自动识别：密钥 / 密码；密码交由 **macOS Keychain** 加密存储，配置文件不落明文

**内置终端**
- 🖥 真实 PTY 终端（[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)），无需外部 Terminal
- 🔐 密码主机用 OpenSSH askpass **自动填充**（复用 Keychain）；标记后可**自动 `sudo -i`**
- 🧩 会话标签页，⌘1–9 切换；⌘T 开本机 shell；⌘W 关当前会话
- 📊 状态栏实时远端 **CPU / 内存 / 时间**（经 ControlMaster 复用连接采集，不打扰终端）
- 📝 运行 vim/vi 时右上角弹**速查表**(可收起为浮窗图标)
- 🎨 内置多款配色(Dracula/Nord/Solarized/Gruvbox/Tokyo Night/One Dark)，也可导入 **iTerm2 `.itermcolors`**；字体、字号可调

**文件与运维**
- 📁 可视化 **SFTP**（[Citadel](https://github.com/orlandos-nl/Citadel)）：左远程/右本地双栏，拖拽/双击传输、新建/重命名/删除，**右键 AI 改文件**
- ⚡ 批量 / 舰队执行：多选主机并发跑同一命令、聚合输出
- 🔀 图形化端口转发（`ssh -L`，支持跳板机，一键启停）
- 🧰 命令片段库：多行命令、`{{占位符}}` 运行时弹窗填参
- 💾 加密备份与迁移：主机 + Keychain 密码导出为口令加密文件；支持**备份到 WebDAV**(仅上传密文)

**原生体验与个性化**
- 🖼 整窗**壁纸**：图片或循环 **mp4**，面板半透明叠加(不可见时自动暂停解码)
- ⌨️ **可自定义快捷键**：录制式设置、冲突检测，全部动作可改键
- 🌐 中文 / English 运行时切换；隐藏标题栏融入深色 UI；自定义设置窗口

> 无服务端、无中心数据库，所有状态都在本机。

---

## 🚀 构建与运行

需要 **Xcode 26+ / Swift 6.2**（macOS 14+）。

```bash
# 生成可运行的 .app 并打开
./scripts/bundle.sh --run

# 打包分发（.dmg + .zip，ad-hoc 签名）
./scripts/package.sh

# 只跑核心逻辑单元测试
swift test
```

`bundle.sh` 会 release 构建、组装 `build/Wireline.app`（含 Info.plist + 自动生成图标），并做 ad-hoc 签名以便本机 Keychain 正常工作。也可用 Xcode 打开 `Package.swift` 直接运行（⌘R）。

### 开发热重载
- `./scripts/dev.sh`：监听 `Sources/`，改动自动重建 debug 包并重启。
- 或用 Xcode + [InjectionIII](https://github.com/johnno1962/InjectionIII/releases)（已接入 [Inject](https://github.com/krzysztofzablocki/Inject)，release 自动 no-op）。

---

## 🧱 架构

两个 SwiftPM target：

- **`WirelineCore`** — 纯 Swift 库，无 UI，可单测
  - `SSHConfig` / `ConfigRepository`：解析回写标准 `~/.ssh/config`，元数据以 `# wireline:` 注释内嵌；原子写入 + 时间戳备份 + 0600 权限
  - `KeychainService`（Security framework）· `SSHCommand` / `PortForwardManager` · `BackupService`（PBKDF2-SHA256 + AES-GCM）
- **`Wireline`** — SwiftUI 应用
  - `HostStore` / `SessionStore` / `ForwardStore` / `AIConfig` / `AIChatStore`（`@Observable`）
  - 内置终端(SwiftTerm)、SFTP(Citadel actor 隔离)、远端指标(ControlMaster)、AI 客户端(OpenAI 兼容流式)、舰队并发执行

依赖：SwiftTerm（终端）· Citadel（SFTP）· Inject（仅 debug 热重载）。

---

## 🔒 安全说明

- 密码 / AI Key 仅存于 macOS Keychain，配置文件里只保留 `auth=password` 标记。
- AI：发送前可脱敏(密码/token 打码)；生成命令**永不自动执行**；Agent 高危命令强制确认，另可开只读沙盒。
- 备份口令不落盘、不上传；丢失口令等同于备份不可恢复。
- 除你配置的 AI 服务外无任何网络回传；SSH 连接均在本机与目标服务器间直接发生。
- 写入 `~/.ssh/config` 前自动时间戳备份，并强制 0600 权限。

---

## 许可

MIT。详见 [LICENSE](LICENSE)。
