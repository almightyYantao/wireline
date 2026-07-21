<p align="center">
  <img src="docs/banner.svg" alt="Wireline" width="860">
</p>

<p align="center">
  <b>English</b> · <a href="README.zh-CN.md">简体中文</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/almightyYantao/wireline/releases/latest">Download</a>
  &nbsp;·&nbsp;
  <a href="https://almightyyantao.github.io/wireline/">Website</a>
  &nbsp;·&nbsp;
  <a href="https://yantao.wiki">Blog</a>
</p>

> A native macOS SSH **fleet manager** that never locks up your data — and lets AI turn batch ops across every host into one sentence.

**Your data is never held hostage.** Host config **always lives in the standard `~/.ssh/config` as the single source of truth** — the GUI is just an efficient shell over that standard file. Uninstall Wireline and `ssh` / `scp` / `rsync` / VS Code Remote still read the same config. No proprietary account, no cloud sync you can't opt out of, no export button you'll ever need. That's the difference between Wireline and the SSH clients that lock your hosts inside their own format.

**Built for many hosts, not one.** Aliases, groups, and batch ops are first-class: select a whole group, describe the task in one sentence, and Wireline fans out in parallel and aggregates every host's output into a single conclusion or table — no need to connect first. A plain AI terminal can't do this, because it doesn't have your host graph.

**AI is the lever, not the pitch.** Layered on top is an assistant that actually *does things*: plain language → command, diagnose errors, edit remote files with a change review, even set up tunnels or add hosts for you — always with confirmation, secrets redacted before sending.

Wrapped in a native macOS terminal-hacker look (monospace · green-on-black · themeable), with a real built-in PTY terminal, a visual SFTP browser, graphical port forwarding, and an app-wide animated wallpaper.

## 📸 Screenshots

<p align="center">
  <video src="https://github.com/almightyYantao/wireline/raw/main/docs/ai-demo.mp4" controls muted width="90%"></video>
</p>

<p align="center"><img src="docs/image/wallpaper.png" width="90%" alt="App-wide wallpaper & themes"></p>
<p align="center">
  <img src="docs/image/files.png" width="90%" alt="Dual-pane SFTP browser">
</p>

---

## 🚀 Fleet

The thing a single-host AI terminal can't give you: operate a whole group at once, because Wireline knows your host graph.

- **One sentence, many hosts**: select hosts or a whole group, describe the task once, and it runs in parallel across all of them
- **Aggregated, not dumped**: per-host output stays collapsible while AI distills everything into one conclusion or comparison table on top
- **No connect required**: a non-interactive engine runs the batch without opening a session per host
- **Safe at scale**: dangerous commands still require confirmation before they touch the fleet; secrets redacted before sending
- **Group- and alias-aware**: target machines by their `~/.ssh/config` alias or group name — the same names `ssh` already uses

---

## ⚔️ Wireline vs Termius vs Warp

| | **Wireline** | Termius | Warp |
|---|---|---|---|
| Positioning | Native macOS SSH **fleet manager** | Cross-platform SSH client | AI-native terminal |
| Host data in plain `~/.ssh/config` | ✅ single source | ❌ own vault | — doesn't manage hosts |
| Works fully local, no account | ✅ | ⚠️ account for sync/AI | ✅ (login optional since 2026) |
| Bring-your-own AI endpoint / full local Ollama | ✅ all AI, incl. the fleet agent | ❌ cloud model only, no BYOK | ⚠️ local AI for command-gen only; agent is cloud |
| Fleet: group → one sentence → parallel → AI aggregates to a table | ✅ | ⚠️ broadcast input (no synthesis) or cloud chat agent | ❌ no host graph |
| MCP tools, local-first (your model calls them) | ✅ stdio + HTTP, secrets in Keychain | ❌ | ⚠️ via its cloud agent |
| Visual SFTP browser | ✅ | ✅ | ❌ |
| GUI port forwarding | ✅ | ✅ | ❌ |
| AI edit remote file + change review | ✅ | ❌ | ❌ |
| NL → command / diagnose | ✅ | ✅ | ✅ (most polished) |
| Cross-platform (Win/Linux/mobile) | ❌ macOS only | ✅ | ✅ desktop |

*Competitor capabilities as of 2026-07 — they move fast; verify against current releases.*

**What only Wireline does, all at once:** keep your hosts in plain `~/.ssh/config` (no lock-in), run **every** AI feature — including the fleet agent — on your own endpoint or fully offline via Ollama, and command a whole group in one sentence with the output distilled into a single table.

> Warp added local AI but still won't manage your hosts. Termius manages hosts but locks them in its vault and runs AI only in its cloud. Wireline keeps your hosts in plain `~/.ssh/config`, runs AI on your own model (or fully offline), and commands the whole fleet in one sentence.

---

## 🤖 AI Copilot

AI is the lever that makes the above feel effortless — not a bolt-on. In Settings → AI, enter an **OpenAI-compatible endpoint + key** (a relay or direct), or point it at local **Ollama** (nothing leaves your machine). The ✨ button by the terminal opens the AI panel.

- **Natural language → command**: describe it, get a command, `Insert` or `Run` — never auto-executed
- **Command bar (⌘;)**: describe → generate → ⌘; again to run
- **Diagnose / Explain / Summarize**: analyze terminal output, explain commands (with danger warnings), summarize long logs
- **Agent mode**: AI runs a command → reads the output → continues, until it reaches a conclusion
  - visible-in-terminal or out-of-band execution; **dangerous commands require confirmation**; **read-only sandbox** blocks all writes
- **Fleet run**: select many hosts → one sentence → parallel execution → AI aggregates into a conclusion/table
- **Copilot for the app itself**: create tunnels, add hosts, connect, open files, run snippets — all with confirmation
- **MCP tools (local-first)**: connect local **stdio** or remote **HTTP** MCP servers (filesystem / GitHub / k8s / …); the AI calls their tools and feeds results back — model-agnostic, secrets in the Keychain, read-only tools run freely while mutating ones need confirmation (or the read-only sandbox blocks them)
- **Built-in ops skills**: curated playbooks (load/CPU, disk, service health, container audit, security baseline) the AI loads on demand via progressive disclosure — mostly read-only investigation; add your own
- **AI edit over SFTP**: right-click a remote file → describe the change → preview → **change review (impact + risks)** → write back
- **Change review**: before a dangerous command runs, AI gives an impact & risk assessment to confirm
- **Per-host memory**: the AI remembers durable facts about each machine and factors them into later answers
- **Session recap → Runbook**: turn what you just did into a Markdown runbook (steps / commands / rollback)
- **Offline triage**: when a monitored host drops, AI suggests likely causes in the notification
- **Context references**: `@output` / `@host` / `@history` (semantic command-history recall)
- **Per-host persisted chat history**, **token usage estimate**, **main/fast model switching**, **redaction before sending**, **save-as-snippet**

---

## 🐾 Desktop Pet

A draggable, always-on-top little sprite that floats over your desktop the moment you open Wireline — its own AI conversation window, distinct from the terminal panel. Summon or dismiss it with **⌥⌘J** — a **system-wide** hotkey, so it works from any app, not just when Wireline is frontmost — or click it. Closing the chat hands keyboard focus back to your terminal.

- **Talk in plain language, it picks the target(s)**: "summarize the running docker containers on `fn`", or "summarize Docker status across all `IAI` hosts" — it resolves the machine(s) **by alias or by group**, runs the command across them in parallel (via the same non-interactive fleet engine — **no need to connect first**), and hands you one summary
- **Multi-host by default**: one sentence can fan out to a whole group; per-host results are collapsible, with an overall AI conclusion on top
- **Safe**: dangerous commands still require confirmation before running on your fleet; secrets redacted before sending
- **Floating & tidy**: borderless, transparent, drag it anywhere; the chat unfolds *upward* so the pet stays put under your cursor; its own persisted history
- Toggle it on/off in **Settings → AI → Desktop Pet**

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
- 🔍 Global quick-connect (⌥⌘K): a **system-wide** hotkey that activates Wireline from any app and opens a Spotlight-style fuzzy search over alias/description/group
- 🗂 Merged host list in the sidebar: grouped, collapsible (remembered), drag-into-group, right-click new/delete group
- 🟢 Reachability checks: `online / offline / checking`; optional background monitoring + notifications
- 🔑 Auth auto-detection: key / password; passwords stored in the **macOS Keychain**, never in plaintext

**Built-in terminal**
- 🖥 Real PTY terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)), no external Terminal needed
- 🔐 Password hosts auto-fill via OpenSSH askpass (reusing the Keychain); optional auto `sudo -i` that auto-enters the saved password — even on key-auth hosts
- 🧩 Session tabs (numbered, double-click to rename inline); ⌘1–9 to switch; ⌘T local shell; ⌘W close current
- 🪟 **Split panes**: drag a tab onto another's edge to merge them into one split tab; ⌘[ / ⌘] cycle pane focus; detach a pane back to its own tab
- 📡 **Broadcast input**: type once, send to every open session at once
- 🔎 **In-terminal search (⌘F)** over the scrollback with match highlighting
- 🔔 **Command-finished notifications**: get pinged when a long command completes while the app is in the background
- 📼 **Session logging**: record a session's output to a file, reveal in Finder
- ♻️ **Session restore**: reopens (and reconnects) the tabs you had open at last quit
- 📊 Live remote **CPU / memory / time** in the status bar (via a reused ControlMaster connection)
- 📝 A vim/vi cheat-sheet pops up while editing (collapsible to a floating icon)
- 🎨 Built-in themes (Dracula/Nord/Solarized/Gruvbox/Tokyo Night/One Dark) or import **iTerm2 `.itermcolors`**; font & size adjustable

**Files & ops**
- 📁 Visual **SFTP** ([Citadel](https://github.com/orlandos-nl/Citadel)): dual-pane, drag/double-click transfers, new/rename/delete, **right-click AI edit**
- 📥 **ZMODEM transfer**: run `sz` on the remote and Wireline catches it automatically — files land in `~/Downloads` (revealed in Finder); `rz` uploads via a file picker (bridges the local `lrzsz` — `brew install lrzsz`)
- ⚡ Batch / fleet execution across selected hosts, aggregated output
- 🔀 Graphical port forwarding (`ssh -L`, jump hosts, one-click toggle)
- 🧰 Command snippets: multi-line commands, `{{placeholders}}` prompt-filled at run time
- 🔑 **SSH key manager**: list `~/.ssh` keys with fingerprints, generate (ed25519/rsa/ecdsa), import keys from elsewhere (fixes permissions), copy public key, or deploy to a host via `ssh-copy-id`
- 💾 Encrypted backup & migration to a file, or **to WebDAV** (ciphertext only) — to-dos ride along too

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

## Star History

<a href="https://star-history.com/#almightyYantao/wireline&Date">
  <img src="https://api.star-history.com/svg?repos=almightyYantao/wireline&type=Date" alt="Star History Chart" width="600">
</a>

---

## License

MIT. See [LICENSE](LICENSE).
