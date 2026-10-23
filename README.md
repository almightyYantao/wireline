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

Wrapped in a native macOS card-and-capsule interface (light and dark themes, can follow the system), with a GPU-rendered **libghostty** terminal (Ghostty's core), a visual SFTP browser, graphical port forwarding, and an app-wide animated wallpaper.

## 📸 Screenshots

<p align="center">
  <video src="https://github.com/almightyYantao/wireline/raw/main/docs/ai-demo.mp4" controls muted width="90%"></video>
</p>

<p align="center"><img src="docs/image/wallpaper.png" width="90%" alt="Grid splits running Claude Code, node, python and htop — light theme"></p>
<p align="center"><img src="docs/image/splits-dark.png" width="90%" alt="The same splits in the dark theme"></p>
<p align="center">
  <img src="docs/image/command-palette.png" width="32%" alt="⌘P palette">
  <img src="docs/image/ssh-connect.png" width="32%" alt="SSH connection panel">
  <img src="docs/image/snippets.png" width="32%" alt="Snippets popover">
</p>
<p align="center"><img src="docs/image/files.png" width="90%" alt="Dual-pane SFTP browser"></p>

---

## ⚡ GPU terminal

The terminal is **libghostty** — the core of [Ghostty](https://ghostty.org) — drawn on the GPU with **Metal**.

<p align="center"><img src="docs/image/gpu.png" width="90%" alt="A Rust build, a flood of access logs and htop, drawn on the GPU"></p>

- **Drawn on the GPU**: glyphs come from a GPU atlas and every frame is composited by Metal shaders, so the CPU only parses. Fast-scrolling build logs, `tail -f`, huge `cat`s and full-screen TUIs (htop, vim, Claude Code) stay smooth, and scrolling back through long history doesn't stutter.
- **Parsed once**: Wireline owns the PTY and feeds the byte stream straight into libghostty — no multiplexer in between re-parsing everything. What reaches the screen costs one parse.
- **Transparent without halos**: the background is composited with premultiplied alpha, so text over your wallpaper has clean edges in light and dark themes.
- **Resizes that stay clean**: the PTY size changes in step with the grid and the prompt is cleared before reflow (OSC 133), so dragging the window never leaves duplicated or staircased prompts.
- **Fallback**: SwiftTerm (with its own Metal renderer) is still there under Settings → Terminal engine.

---

## 🚀 Fleet

<p align="center"><img src="docs/image/ai-fleet.png" width="90%" alt="Fleet run: one sentence across a host group, results aggregated into a table"></p>

The thing a single-host AI terminal can't give you: operate a whole group at once, because Wireline knows your host graph.

- **One sentence, many hosts**: select hosts or a whole group, describe the task once, and it runs in parallel across all of them
- **Aggregated, not dumped**: per-host output stays collapsible while AI distills everything into one conclusion or comparison table on top
- **No connect required**: a non-interactive engine runs the batch without opening a session per host
- **Safe at scale**: dangerous commands still require confirmation before they touch the fleet; secrets redacted before sending
- **Group- and alias-aware**: target machines by their `~/.ssh/config` alias or group name — the same names `ssh` already uses

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

## ✨ Features

**Connect & manage**
- 🔍 Global quick-connect (⌥⌘K): a **system-wide** hotkey that activates Wireline from any app and opens a Spotlight-style fuzzy search over alias/description/group
- 🗂 Merged host list in the sidebar: grouped, collapsible (remembered), drag-into-group, right-click new/delete group
- 🟢 Reachability checks: `online / offline / checking`; optional background monitoring + notifications
- 🔑 Auth auto-detection: key / password; passwords stored in the **macOS Keychain**, never in plaintext

**Built-in terminal**
- 🚀 **libghostty terminal engine**: Ghostty's core (in a small Wireline fork) with **GPU (Metal) rendering**, ligatures, Nerd Fonts and halo-free transparency; SwiftTerm stays as a fallback under Settings → Terminal engine
- 🔌 **Wireline owns the PTY**: output is parsed exactly once — the engine only parses and draws; ZMODEM, password / sudo auto-answer and session logs work on the raw byte stream, for both engines
- 📐 **Clean resizes**: during a live window drag the PTY size changes with the grid, and with OSC 133 the prompt is cleared before reflow, so p10k-style multi-line / right prompts never duplicate or staircase; sidebar, AI panel and fullscreen changes reflow once with a smooth transition
- 🛰 **SSH connection panel**: resolve → connect → authenticate → session progress with logs; a readable reason and Retry on failure; steps aside when a passphrase or OTP prompt needs you
- 🔐 Password hosts auto-fill via OpenSSH askpass (reusing the Keychain); optional auto `sudo -i` with the saved password — even on key-auth hosts; **Touch ID protection for existing keys** (built-in ssh-agent, still system OpenSSH)
- 🧩 **Tabs**: capsule tabs level with the traffic lights, with a sliding active pill; each pane shows the program it's running (Claude, Codex, Node, Python, Git, Docker, vim…); click the active tab to rename it (split tabs too); ⌘1–9, ⌘T local shell, ⌘W close pane
- 🪟 **Splits**: ⌘D fills a two-wide grid, ⇧⌘D splits down, ⌥-arrows move focus, drag the gap to resize (double-click to even out), ⇧⌘↩ zooms in place; closing a pane returns to the one you were in; drop a tab or host on a pane edge to merge / open there
- ⏪ **Prompt-aware (OSC 133)**: ⌘↑ / ⌘↓ jump between prompts, ⌥⌘C copies the last command's output, completion notifications include the exit code
- 🔎 **Search (⌘F)** with highlighting, **regex** and case sensitivity
- ⚡ **Quick terminal**: global ⌃` drops one down from the top of the screen
- 📡 **Broadcast input**: type once, send to every open session
- 📼 **Session logging**: record a session's output to a file, reveal in Finder
- ♻️ **Session restore**: reopens and reconnects your tabs, keeping split layouts and working directories
- 📊 Live remote **CPU / memory / time** in the status bar (via a reused ControlMaster connection)
- 📝 A vim/vi cheat-sheet pops up while editing (collapsible to a floating icon)
- 🎨 Light and dark themes, or import **iTerm2 `.itermcolors`**; a **Ghostty-style config file** at `~/.config/wireline/config` with live reload and Ghostty action names in keybinds

**Files & ops**
- 📁 Visual **SFTP** ([Citadel](https://github.com/orlandos-nl/Citadel)): dual-pane, drag/double-click transfers, new/rename/delete, **right-click AI edit**
- 📥 **ZMODEM transfer**: run `sz` on the remote and Wireline catches it automatically — files land in `~/Downloads` (revealed in Finder); `rz` uploads via a file picker (bridges the local `lrzsz` — `brew install lrzsz`)
- ⚡ Batch / fleet execution across selected hosts, aggregated output
- 🔀 Graphical port forwarding (`ssh -L`, jump hosts, one-click toggle)
- 🧰 **Snippets**: search them from the ⚡ popover or ⌘P (English, Chinese or pinyin); Return inserts, ⌘Return runs; `{{name}}` parameters filled in place and remembered; Linux / macOS scopes; scripts and dangerous commands ask first
- 🔑 **SSH key manager**: list `~/.ssh` keys with fingerprints, generate (ed25519/rsa/ecdsa), import keys from elsewhere (fixes permissions), copy public key, or deploy to a host via `ssh-copy-id`
- 💾 Encrypted backup & migration to a file, or **to WebDAV** (ciphertext only)

**Native experience & personalization**
- 🖼 App-wide **wallpaper**: image or looping **mp4**, translucent panels over it (paused when off-screen)
- 🧭 **One palette for ⌘K / ⌘P**: type to find hosts, `>` for commands; matches English, Chinese and pinyin
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

The libghostty engine ships as a prebuilt `GhosttyKit.xcframework` in `Vendor/` (~280 MB, not in git), put there by `./scripts/fetch-ghosttykit.sh`. It's built from Wireline's Ghostty fork (patches: a host-owned-PTY IO backend, last-command output, regex search …) with Zig 0.17; the fork and prebuilt archives will be published to Releases, after which this step downloads and verifies them automatically.

RDP panes link a static **FreeRDP 3** (+ OpenSSL) from `Vendor/FreeRDP/` (~35 MB universal, not in git): `./scripts/fetch-freerdp.sh --build` builds it with `scripts/build-freerdp.sh` (cmake + ninja; FreeRDP and OpenSSL are fetched and compiled for macOS 14, arm64 + x86_64, no FFmpeg — so no H.264, RemoteFX / progressive instead).

`bundle.sh` does a release build, assembles `build/Wireline.app` (Info.plist + a generated icon), and ad-hoc signs it so the local Keychain works. You can also open `Package.swift` in Xcode and run (⌘R).

### Live reload for development
- `./scripts/dev.sh`: watches `Sources/`, rebuilds the debug bundle and restarts on change.
- Or Xcode + [InjectionIII](https://github.com/johnno1962/InjectionIII/releases) (wired via [Inject](https://github.com/krzysztofzablocki/Inject); no-op in release).

---

## 🧱 Architecture

Two SwiftPM targets:

- **`WirelineCore`** — pure Swift, no UI, unit-testable
  - `SSHConfig` / `ConfigRepository`: parse & write back the standard `~/.ssh/config`, with metadata inlined as `# wireline:` comments; atomic writes + timestamped backups + 0600 perms
  - `PTYProcess`: our own PTY (forkpty, so the child gets its controlling terminal; ordered writes, back-pressure, output drained before exit)
  - `KeychainService` (Security framework) · `SSHCommand` / `PortForwardManager` · `BackupService` (PBKDF2-SHA256 + AES-GCM) · SSH connect-log parsing, snippet parameters and other pure logic
- **`Wireline`** — SwiftUI + AppKit app
  - The terminal in three layers: `TerminalIO` (PTY and byte-stream work: ZMODEM, password answers, logging, busy detection) → the `TerminalEngine` protocol → two implementations, `GhosttyTerminalView` (libghostty, Metal) and `WirelineTerminalView` (SwiftTerm)
  - `HostStore` / `SessionStore` / `ForwardStore` / `AIConfig` / `AIChatStore` (`@Observable`)
  - SFTP (Citadel, actor-isolated), remote metrics (ControlMaster), AI client (OpenAI-compatible streaming), concurrent fleet execution

```
ssh / zsh ⇄ PTYProcess ⇄ TerminalIO ──bytes──▶ engine (libghostty / SwiftTerm) ──▶ Metal / CoreGraphics
                          (ZMODEM · passwords · logs)  ◀──keys & terminal replies──
```

Dependencies: libghostty (terminal, Wireline fork) · SwiftTerm (fallback terminal) · Citadel (SFTP) · Sparkle (updates) · Inject (debug live reload only). Program icons from [Simple Icons](https://simpleicons.org) (CC0).

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

Third-party: Ghostty (MIT; its license ships in `Contents/Resources/ghostty/LICENSE`) and the libraries it links statically (freetype, harfbuzz, oniguruma …); FreeRDP (Apache-2.0) and OpenSSL (Apache-2.0), linked statically for RDP panes (licences in `Contents/Resources/FreeRDP/`); SwiftTerm (MIT); Citadel (MIT); Sparkle (MIT); Simple Icons (CC0).

Wireline itself: MIT. See [LICENSE](LICENSE).
