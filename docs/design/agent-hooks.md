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

## Not covered

- SSH panes: the remote shell has no socket. Would need a reverse-forwarded
  socket (`ssh -R`) or OSC in-band messages.
- Other agents (Codex …) still run on the heuristics.
- Uninstall button.
