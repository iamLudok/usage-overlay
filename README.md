# usage-overlay

A tiny, always-on-top, click-through overlay for Windows that shows how much
of your AI coding-agent quota you have used. Bars are green under 60%, amber
from 60%, red from 85%, with a countdown to each window reset. On fetch
failures it keeps the last good numbers (shown amber) and retries. Click the
`?` button for a built-in legend.

![usage overlay](docs/overlay.png)

| Section | Tool | Where the data comes from |
|---------|------|---------------------------|
| `CLAUDE` | Claude Code | `api.anthropic.com/api/oauth/usage`, using the OAuth token from `~/.claude/.credentials.json`. |
| `CODEX` | OpenAI Codex CLI | Last `rate_limits` event in the newest `~/.codex/sessions` log (local read). |
| `CURSOR` | Cursor | `cursor.com/api/usage-summary`, using the session token stored in Cursor's `state.vscdb`. |
| `COPILT` | GitHub Copilot | Official billing API (`ai_credit/usage`), using a fine-grained PAT set in `config.json`. Off by default; see Configuration below. |
| `OPENCD` | OpenCode | Local spend tracked in `opencode.db`, shown as $ spent (Zen has no quota API). |

The overlay only reads credentials and data those tools leave behind; it
never logs in for you. Node.js is required for the `CURSOR` and `OPENCD`
sections.

## Run / stop

```powershell
powershell -WindowStyle Hidden -File usage-overlay.ps1
powershell -File stop-overlay.ps1
```

Or use the tray icon (next to the clock): right-click it for Refresh now,
Restart, and Exit.

## Moving the overlay

Hold Ctrl and drag the overlay with the left mouse button to place it
anywhere on screen. The position is saved automatically and wins over the
`corner` setting below; delete the auto-written `x`/`y` keys from
`config.json` to go back to docking by corner.

## Configuration (optional)

Copy `config.example.json` to `config.json` and edit what you need. Missing
keys keep their defaults; `config.json` is git-ignored.

| Key | Values | Meaning |
|-----|--------|---------|
| `corner` | `top-right`, `top-left`, `bottom-right`, `bottom-left` | Screen corner the overlay docks to. |
| `marginX`, `marginY` | pixels | Distance from the work-area edge. |
| `refreshSeconds` | 15 or more | Redraw interval. Remote APIs are still polled only every 3rd tick. |
| `sections` | `"auto"` or e.g. `["claude", "codex"]` | `auto` shows only the tools with local data on this machine. |
| `githubUser`, `githubToken` | your login, a PAT | Enables the `COPILT` section. Create a fine-grained personal access token with Account permissions -> Plan -> Read-only, nothing else. |
| `copilotIncluded` | number, default 200 | Monthly AI credits included in your Copilot plan, used to compute the percentage (the API only reports consumption, not the limit). |
| `x`, `y` | pixels | Auto-written when you Ctrl+drag the overlay; delete to go back to corner docking. |

## License

[MIT](LICENSE)
