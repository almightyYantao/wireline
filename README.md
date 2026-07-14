# Wireline

> 一个别名，连接一切 —— 原生 macOS SSH 客户端
>
> *One alias to connect them all — a native macOS SSH client.*

Wireline 把命令行时代验证过的高效范式（别名、分组、批量、安全存储）重新设计为一款原生 macOS 客户端。主机数据**始终以标准 `~/.ssh/config` 为唯一数据源**——图形界面只是这份标准配置之上的高效外壳。卸载 Wireline 后，`ssh` / `scp` / `rsync` / VS Code Remote 仍能直接读取同一份配置，绝不锁定。

界面走终端黑客风（等宽字体 · 绿黑配色），内置真实 PTY 终端、可视化 SFTP 文件管理、图形化端口转发与批量运维。

---

## ✨ 功能

**连接与管理**
- 🔍 全局快捷连接（⌘K）：Spotlight 式模糊搜索别名/描述/分组，回车即连
- 🗂 侧栏合并主机列表：按分组分区展示、可折叠（状态记忆）、拖拽主机入组、右键新建/删除分组
- 🟢 连通性探测：TCP 可达性检查，标签显示 `在线 / 离线 / 探测中`，已建立会话的主机显示 `已连接`
- 🔑 认证自动识别：密钥 / 密码；密码交由 **macOS Keychain** 加密存储，配置文件不落明文

**内置终端**
- 🖥 真实 PTY 终端（基于 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)），无需外部 Terminal
- 🔐 密码主机用 OpenSSH askpass 机制**自动填充**（复用 Keychain），标记后可**自动 `sudo -i`**
- 🧩 会话标签页；⌘T 开本机登录 shell（走 `.zshrc`，主题/图标原样呈现）；⌘W 关当前会话
- 📊 底部状态栏实时显示远端 **CPU / 内存 / 时间**（经 SSH ControlMaster 复用连接采集，不打扰终端）
- 🎨 可自定义：导入 **iTerm2 `.itermcolors`** 配色、等宽字体与字号、背景图片与不透明度

**文件与运维**
- 📁 可视化 **SFTP 文件管理**（基于 [Citadel](https://github.com/orlandos-nl/Citadel)）：左远程/右本地双栏，拖拽或双击上传下载、新建文件夹、重命名、删除
- ⚡ 批量命令执行：多选主机并发跑同一命令、聚合输出
- 🔀 图形化端口转发（`ssh -L`，支持跳板机，一键启停）
- 💾 加密备份与迁移：一键导出主机 + Keychain 密码为口令加密文件，新机一键导入

**原生体验**
- 菜单栏常驻、隐藏标题栏融入深色 UI、可切回 Terminal.app / iTerm2

> 无服务端、无中心数据库，所有状态都在本机。

---

## 🚀 构建与运行

需要 **Xcode 26+ / Swift 6.2**（macOS 14+）。

```bash
# 生成可运行的 .app 并打开
./scripts/bundle.sh --run

# 只跑核心逻辑单元测试
swift test
```

`bundle.sh` 会 release 构建、组装 `build/Wireline.app`（含 Info.plist + 自动生成的应用图标），并做 ad-hoc 签名以便本机 Keychain 正常工作。

> 也可用 Xcode 打开 `Package.swift` 直接运行（⌘R）。

### 开发热重载
- `./scripts/dev.sh`：监听 `Sources/`，改动自动重建 debug 包并重启（无需 Xcode）。
- 或用 Xcode + [InjectionIII](https://github.com/johnno1962/InjectionIII/releases) 真·热重载（已接入 [Inject](https://github.com/krzysztofzablocki/Inject)，release 自动 no-op）。

### 试用示例配置
`examples/ssh_config.sample` 展示了带 Wireline 元数据的 config。默认读写真实的 `~/.ssh/config`；仅想体验可先备份自己的配置。

---

## 🧱 架构

两个 SwiftPM target：

- **`WirelineCore`** — 纯 Swift 库，无 UI，可单测
  - 配置层 `SSHConfig` / `ConfigRepository`：解析并回写标准 `~/.ssh/config`，工具元数据以 `# wireline:` 注释行内嵌（原生 ssh 忽略）；原子写入 + 时间戳备份 + 0600 权限
  - 凭据层 `KeychainService`：Security framework generic password
  - 连接层 `SSHCommand` / `SSHLauncher` / `BatchExecutor` / `PortForwardManager`
  - 备份层 `BackupService`：PBKDF2-SHA256 派生密钥 + CryptoKit AES-GCM
- **`Wireline`** — SwiftUI 应用
  - `HostStore` / `SessionStore` / `ForwardStore`（`@Observable`）+ 各视图
  - 内置终端（SwiftTerm）、SFTP 文件浏览（Citadel actor 隔离）、远端指标采集（ControlMaster）

依赖：SwiftTerm（终端）· Citadel（SFTP）· Inject（仅 debug 热重载）。

---

## 🔒 安全说明

- 密码仅存于 macOS Keychain，配置文件里只保留 `auth=password` 标记。
- 备份口令不落盘、不上传；丢失口令等同于备份不可恢复。
- 无任何网络回传，所有连接均在本机与目标服务器之间直接发生。
- 写入 `~/.ssh/config` 前自动时间戳备份，并强制 0600 权限。

> ⚠️ SFTP 浏览目前主机密钥校验为 `acceptAnything`（首次连接不校验 known_hosts），加密私钥（带 passphrase）与经跳板机的 SFTP 暂不支持——欢迎 PR。

---

## 🗺 路线图

- [ ] 已加密私钥（passphrase）与 ProxyJump 下的 SFTP
- [ ] known_hosts 校验
- [ ] FTP 传输、文件断点续传
- [ ] 团队共享主机清单（脱敏元数据）与操作审计

---

## 许可

MIT。详见 [LICENSE](LICENSE)。
