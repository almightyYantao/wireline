# Coding-agent hooks

`CodingAgentTracker` guesses an agent's state from output rhythm, bells and
titles. For Claude Code in a local pane, its own hooks report the state exactly.

## Channel

- The app listens on `~/Library/Application Support/Wireline/mcp/hooks-v1.sock`
  (`AgentHooks.socketPath`, `AgentHookServer`), mode 0600, same-UID peers only.
  It is a separate socket from MCP: `nc` isn't signed, so `PeerIdentity` can't vet it.
- Every local shell gets `WIRELINE_SESSION_ID=<pane uuid>` and
  `WIRELINE_HOOK_SOCK=<socket path>` (only once the socket is up).
- Protocol: one line per connection, `<session uuid> <event> [hook JSON]\n`.
  The app reads up to the newline and closes.

## Hook command

Installed under `UserPromptSubmit`, `Notification` and `Stop` in
`~/.claude/settings.json`:

```sh
[ -n "$WIRELINE_SESSION_ID" ] && [ -S "$WIRELINE_HOOK_SOCK" ] && { printf '%s Stop ' "$WIRELINE_SESSION_ID"; tr -d '\n'; echo; } | nc -U -w 1 "$WIRELINE_HOOK_SOCK" >/dev/null 2>&1; true
```

Outside Wireline (no env vars) or with the app gone it's a no-op, and it always exits 0.
It uses env vars, not literal paths, so the settings never go stale.

## Mapping

| Hook | State |
|---|---|
| UserPromptSubmit | working |
| Notification | needsYou(message) |
| Stop | done |

The first hook event marks the tracker `hookDriven`: output quiet, titles and bells
stop changing state. Typing while it waits for you resumes `working` (you answered
the prompt); `done` holds until the next `UserPromptSubmit`.

## Install

Settings → General → "Install hooks for Claude Code" merges the three entries
(`AgentHooks.merged`): existing hooks are kept, ours are recognised by the
`WIRELINE_HOOK_SOCK` marker so installing again is a no-op, and the old file is
copied to `settings.json.wireline-backup` first.

## SSH panes: in-band OSC

Env vars and sockets don't cross SSH, so remote hooks report in-band. The hook
writes to its controlling terminal (its stdout is captured by Claude Code):

```sh
{ printf '\033]1337;WirelineHook=Stop;'; { head -c 2000; cat >/dev/null; } | base64 | tr -d '\n'; printf '\007'; } 2>/dev/null >/dev/tty; true
```

- `TerminalStreamSniffer` reports `OSC 1337;WirelineHook=<event>;<base64 JSON>`
  as `.agentHook`; `TerminalIO.onAgentHook` → `IslandCenter.agentHook(remote: true)`,
  SSH sessions only. The JSON is cut at 2000 bytes so the OSC stays under the
  sniffer's 4096 limit; `message` is still read from a cut payload.
- Install: right-click an SSH pane → "Install Claude Code Hooks on This Host…",
  confirmed in an alert, then merged over SFTP (`AgentHooks.merged(remote: true)`,
  marker `WirelineHook=`, backup `settings.json.wireline-backup`). Never automatic.
- Other terminals ignore unknown OSC 1337 keys. Any remote output can spoof
  it (e.g. `cat` of a crafted file); the effect is limited to the island's state.
- Why not `ssh -R` of the socket: needs `StreamLocalBindUnlink`, sshd
  `AllowStreamLocalForwarding`, a per-connection remote path and env plumbing
  (`SendEnv`/`SetEnv` are often refused); OSC needs nothing on the server.

## Not covered

- tmux / screen on the remote swallow the OSC unless passthrough is on
  (`set -g allow-passthrough on` plus DCS wrapping) — not done.
- Hooks spawned without a controlling terminal (`/dev/tty` unavailable) are silent.
- Other agents (Codex …) still run on the heuristics.
- Uninstall button.
