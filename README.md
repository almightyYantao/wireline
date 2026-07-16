<p align="center">
  <img src="docs/banner.svg" alt="Wireline" width="860">
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/almightyYantao/wireline/releases/latest">Download</a>
  &nbsp;·&nbsp;
  <a href="https://almightyyantao.github.io/wireline/">Website</a>
</p>

> A native macOS SSH client with a built-in AI copilot.

Wireline reimagines the command-line era's proven workflow (aliases, groups, batch ops, secure storage) as a native macOS app — and layers on an AI assistant that can actually *do things*: turn plain language into commands and run them, fan out across hosts, diagnose errors, even set up tunnels or add hosts for you.

Your host data **always lives in the standard `~/.ssh/config` as the single source of truth** — the GUI is just an efficient shell over that standard file. Uninstall Wireline and `ssh` / `scp` / `rsync` / VS Code Remote still read the same config. No lock-in.

A terminal-hacker look (monospace · green-on-black · themeable), a real built-in PTY terminal, a visual SFTP browser, graphical port forwarding, and even an app-wide animated wallpaper.

## 📸 Screenshots

<p align="center">
  <video src="https://github.com/almightyYantao/wireline/raw/main/docs/ai-demo.mp4" controls muted width="90%"></video>
</p>

<p align="center"><img src="docs/image/wallpaper.png" width="90%" alt="App-wide wallpaper & themes"></p>
<p align="center">
  <img src="docs/image/files.png" width="90%" alt="Dual-pane SFTP browser">
</p>

---

## 🤖 AI Copilot

In Settings → AI, enter an **OpenAI-compatible endpoint + key** (a relay or direct), or point it at local **Ollama** (nothing leaves your machine). The ✨ button by the terminal opens the AI panel.

- **Natural language → command**: describe it, get a command, `Insert` or `Run` — never auto-executed
- **Command bar (⌘;)**: describe → generate → ⌘; again to run
- **Diagnose / Explain / Summarize**: analyze terminal output, explain commands (with danger warnings), summarize long logs
- **Agent mode**: AI runs a command → reads the output → continues, until it reaches a conclusion
  - visible-in-terminal or out-of-band execution; **dangerous commands require confirmation**; **read-only sandbox** blocks all writes
- **Fleet run**: select many hosts → one sentence → parallel execution → AI aggregates into a conclusion/table
- **Copilot for the app itself**: create tunnels, add hosts, connect, open files, run snippets — all with confirmation
- **AI edit over SFTP**: right-click a remote file → describe the change → preview → **change review (impact + risks)** → write back
- **Change review**: before a dangerous command runs, AI gives an impact & risk assessment to confirm
- **Per-host memory**: the AI remembers durable facts about each machine and factors them into later answers
- **Session recap → Runbook**: turn what you just did into a Markdown runbook (steps / commands / rollback)
- **Offline triage**: when a monitored host drops, AI suggests likely causes in the notification
- **Context references**: `@output` / `@host` / `@history` (semantic command-history recall)
- **Per-host persisted chat history**, **token usage estimate**, **main/fast model switching**, **redaction before sending**, **save-as-snippet**

---

## ✅ To-Do

A standalone daily checklist that lives right next to your terminals — open it with **⌘D** (remappable) or from the menu-bar icon.

- **Menu-bar extra**: a live count of open items, quick-add, and quick-toggle without opening a window
- **Due date & time** with overdue highlighting, and **system notifications** when an item comes due
- **Priority (star), tags, notes, and nested subtasks** (with `done/total` progress)
- **Recurring items** (daily / weekly / monthly) — completing one spawns the next occurrence automatically
- **Search** and **tag filtering**; filter by all / active / done
- **Keyboard-driven**: ↑↓ to select, space to toggle, return to edit, delete to remove, **⌘Z to undo**
- **AI recap** (reuses your configured endpoint): a natural-language *today / this-month* summary of what you finished and what still needs attention
- **Smart add**: type “submit the report tomorrow 3pm” and the AI fills in the title, due time, and priority
- Composites over the **same wallpaper backdrop** as the main window, and rides along inside the **encrypted backup / migration** — switch Macs and your to-dos come too

Data lives only in a local `todos.json` (plus the opt-in encrypted backup); it never touches `~/.ssh/config`.

---

## ✨ Features

**Connect & manage**
- 🔍 Global quick-connect (⌘K): Spotlight-style fuzzy search over alias/description/group
- 🗂 Merged host list in the sidebar: grouped, collapsible (remembered), drag-into-group, right-click new/delete group
- 🟢 Reachability checks: `online / offline / checking`; optional background monitoring + notifications
- 🔑 Auth auto-detection: key / password; passwords stored in the **macOS Keychain**, never in plaintext

**Built-in terminal**
- 🖥 Real PTY terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)), no external Terminal needed
- 🔐 Password hosts auto-fill via OpenSSH askpass (reusing the Keychain); optional auto `sudo -i`
- 🧩 Session tabs, ⌘1–9 to switch; ⌘T local shell; ⌘W close current
- 📊 Live remote **CPU / memory / time** in the status bar (via a reused ControlMaster connection)
- 📝 A vim/vi cheat-sheet pops up while editing (collapsible to a floating icon)
- 🎨 Built-in themes (Dracula/Nord/Solarized/Gruvbox/Tokyo Night/One Dark) or import **iTerm2 `.itermcolors`**; font & size adjustable

**Files & ops**
- 📁 Visual **SFTP** ([Citadel](https://github.com/orlandos-nl/Citadel)): dual-pane, drag/double-click transfers, new/rename/delete, **right-click AI edit**
- ⚡ Batch / fleet execution across selected hosts, aggregated output
- 🔀 Graphical port forwarding (`ssh -L`, jump hosts, one-click toggle)
- 🧰 Command snippets: multi-line commands, `{{placeholders}}` prompt-filled at run time
- 💾 Encrypted backup & migration to a file, or **to WebDAV** (ciphertext only)

**Native experience & personalization**
- 🖼 App-wide **wallpaper**: image or looping **mp4**, translucent panels over it (paused when off-screen)
- ⌨️ **Customizable keyboard shortcuts**: recording UI, conflict detection
- 🌐 Chinese / English runtime switch; hidden title bar; custom settings window

> No server, no central database — all state lives on your machine.

---

## 🚀 Build & Run

Requires **Xcode 26+ / Swift 6.2** (macOS 14+).

```bash
# Build a runnable .app and open it
./scripts/bundle.sh --run

# Package for distribution (.dmg + .zip, ad-hoc signed)
./scripts/package.sh

# Run the core unit tests
swift test
```

`bundle.sh` does a release build, assembles `build/Wireline.app` (Info.plist + a generated icon), and ad-hoc signs it so the local Keychain works. You can also open `Package.swift` in Xcode and run (⌘R).

### Live reload for development
- `./scripts/dev.sh`: watches `Sources/`, rebuilds the debug bundle and restarts on change.
- Or Xcode + [InjectionIII](https://github.com/johnno1962/InjectionIII/releases) (wired via [Inject](https://github.com/krzysztofzablocki/Inject); no-op in release).

---

## 🧱 Architecture

Two SwiftPM targets:

- **`WirelineCore`** — pure Swift, no UI, unit-testable
  - `SSHConfig` / `ConfigRepository`: parse & write back the standard `~/.ssh/config`, with metadata inlined as `# wireline:` comments; atomic writes + timestamped backups + 0600 perms
  - `KeychainService` (Security framework) · `SSHCommand` / `PortForwardManager` · `BackupService` (PBKDF2-SHA256 + AES-GCM)
- **`Wireline`** — SwiftUI app
  - `HostStore` / `SessionStore` / `ForwardStore` / `AIConfig` / `AIChatStore` (`@Observable`)
  - built-in terminal (SwiftTerm), SFTP (Citadel, actor-isolated), remote metrics (ControlMaster), AI client (OpenAI-compatible streaming), concurrent fleet execution

Dependencies: SwiftTerm (terminal) · Citadel (SFTP) · Inject (debug live reload only).

---

## 🔒 Security

- Passwords and the AI key live only in the macOS Keychain; config files keep just an `auth=password` marker.
- AI: optional redaction before sending; generated commands **never auto-run**; dangerous commands require confirmation in agent mode, with an optional read-only sandbox.
- The backup passphrase is never written to disk or uploaded; lose it and the backup is unrecoverable.
- No network traffic except to the AI endpoint you configure; SSH connections go straight from your machine to the target.
- `~/.ssh/config` is timestamp-backed-up before writes and forced to 0600.

---

## License

MIT. See [LICENSE](LICENSE).
