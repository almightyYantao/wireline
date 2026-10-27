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

## Other agents

`AgentHookTarget.all` (Sources/WirelineCore/AgentHookTargets.swift) lists each agent with a hook mechanism: its config file, format, and event → working / needsYou / done. Non-Claude hooks send `<uuid> <agent>:<event> [json]`; `session_id` / `thread-id` / `conversation_id` in the JSON is passed on as `agentSessionID` for resuming.

| Agent | File | Mechanism | Events |
|---|---|---|---|
| Codex | ~/.codex/hooks.json | hooks (trust once with `/hooks`) | UserPromptSubmit, PermissionRequest, Stop |
| Gemini CLI | ~/.gemini/settings.json | hooks | BeforeAgent, Notification, AfterAgent |
| Qwen Code | ~/.qwen/settings.json | hooks | UserPromptSubmit, Notification, Stop |
| Cursor Agent | ~/.cursor/hooks.json | hooks v1 (flat) | beforeSubmitPrompt, stop (no waiting event) |
| opencode | ~/.config/opencode/plugins/wireline-hooks.js | plugin | session.status busy/idle, permission.asked/replied |
| Amp | ~/.config/amp/plugins/wireline-hooks.ts | plugin | agent.start, agent.end |
| Aider | ~/.aider.conf.yml | notifications-command (marker block) | waiting for input → done |

Goose and Crush have no hook mechanism: still guessed. Agents whose hooks don't cover a whole turn (Cursor, Amp, Aider) don't switch the tracker to hook-only mode. Install keeps the user's config, is idempotent, backs up to `.wireline-backup`, and uninstall removes only entries carrying the marker; plugin files without the marker are never overwritten or deleted.
