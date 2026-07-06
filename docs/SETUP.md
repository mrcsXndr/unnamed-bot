# Setup Guide

## 60-second quickstart

```bash
git clone <your-fork-url> my-bot && cd my-bot

# Windows
pwsh -ExecutionPolicy Bypass -File scripts\setup.ps1
pwsh -File scripts\launch.ps1

# macOS / Linux
bash scripts/setup.sh
bash scripts/launch.sh
```

The wizard asks for exactly three things: **bot name**, **Telegram bot
token**, **Telegram chat id**. Everything else is a yes/no opt-in (all default
NO). Then message your bot on Telegram, run `/telegram:access pair <code>`
once in the terminal, and you're live.

No Telegram? Leave the token blank — the bot runs terminal-only and you can
re-run setup later.

### Prerequisites

| Tool | Why | Get it |
|---|---|---|
| Claude Code | the brain | https://claude.com/claude-code |
| Python 3.10+ | tools/hooks | https://python.org |
| Node.js | statusline, memory-sync, browser | https://nodejs.org |
| git | the repo is the bot's memory | https://git-scm.com |

The setup wizard checks all four and tells you what's missing.

### Creating the Telegram bot (2 minutes)

1. Message [@BotFather](https://t.me/BotFather) → `/newbot` → copy the token.
2. Message your new bot anything.
3. Open `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser and read
   `"chat":{"id":...}` — that number is your chat id.
4. Give both to the setup wizard.
5. After first launch, the bot replies with a pairing code; run
   `/telegram:access pair <code>` in the Claude Code terminal (one-time).

## What setup writes

Everything lands in `.env` (gitignored). The feature flags are plain
`FEATURE_*=0/1` lines — flip them any time with an editor, or re-run setup.

## Opt-in feature matrix

| Feature | Flag / mechanism | What it does | Default |
|---|---|---|---|
| Telegram bridge | `TELEGRAM_BOT_TOKEN` in `.env` | Inbound via the official channel plugin; outbound via `tools/tg/tg_send.py` with auto-HTML + status footer; `/status` `/journal` `/costs` … slash commands | on when token set |
| Google Workspace | `FEATURE_GOOGLE=1` + `credentials.json` | calendar/gmail/tasks/sheets/drive CLI wrappers | off |
| Memory git sync | `FEATURE_MEMORY_SYNC=1` | commit+push `memory/` to your remote on stop, pull on start (cross-machine memory). Touches your GitHub/GitLab remote. | off |
| Auto-commit | `FEATURE_AUTO_COMMIT=1` | local `git commit -A` checkpoint on every session stop (never pushes) | off |
| Session debrief | `FEATURE_SESSION_DEBRIEF=1` | background `claude --print` writes a session log entry on stop (costs tokens) | off |
| Secrets backup | `FEATURE_SECRETS_BACKUP=1` + `SYNC_DRIVE_PATH` | mirror `.env`/`credentials.json`/`token.json` to a cloud/USB folder | off |
| Supervisor (Windows) | scheduled task via `scripts/register-supervisor.ps1` | exactly one healthy bot: cold-start at logon/after crash, heal dead TG poller, commitments heartbeat | off |
| Resource monitors (Windows) | `FEATURE_MONITORS=1` (needs supervisor) | hourly janitor: kills orphaned automation browsers, alerts on low disk/RAM | off |
| TG watchdog (Windows) | scheduled task via `scripts/register-tg-watchdog.ps1` | standalone poller auto-heal if you DON'T want the full supervisor | off |
| Voice transcription | `GROQ_API_KEY` in `.env` | Telegram voice notes → text via Whisper | off |
| Task board | `TASK_BOARD_SHEET_ID` in `.env` | `/tasks` TG command reads a Google Sheet | off |
| Slack / Cloudflare / GitLab / Resend | keys in `.env` | optional CLI helpers under `tools/infra/` | off |

Nothing GitHub- or backup-related runs unless you opt in. Every hook is
fail-open: if a feature is off or broken, sessions still start and stop
cleanly.

## Cross-platform support

| Layer | Windows | macOS / Linux |
|---|---|---|
| Core bot: hooks, journal/timeline/recall, commitments, cost meter, TG send, slash commands, browser automation, Google tools | ✅ | ✅ (hooks are bash; tools are Python/Node) |
| `setup` + `launch` scripts | ✅ `.ps1` | ✅ `.sh` |
| Supervisor / TG watchdog / auto-restart / resource monitor | ✅ scheduled tasks + PowerShell | ❌ not shipped |

This template is **Windows-first for the resilience layer** (that's where the
reference implementation runs), with the core bot fully cross-platform. If you
want auto-restart on Linux/macOS, the moral equivalent is small:

```
# cron sketch (every 3 min): relaunch if no claude process is alive
*/3 * * * * pgrep -f "claude.*--channels" >/dev/null || (cd ~/my-bot && bash scripts/launch.sh --continue >/dev/null 2>&1 &)
```

or a systemd user service with `Restart=on-failure` wrapping
`scripts/launch.sh --continue`. The poller-409 heal logic in
`tools/v2/tg_watchdog.py` is pure Python and portable if you want to wire it
to cron.

## Day-2 operations

- **Launch**: `scripts/launch.(ps1|sh)`. Defaults to `--continue` — long
  sessions are the intended mode; journal/timeline carry context across
  compaction.
- **Talk to it**: Telegram (paired) or the terminal.
- **Slash commands** (from Telegram): `/status`, `/journal [n]`, `/timeline`,
  `/compact`, `/tasks`, `/costs [Nd]`, `/update`, `/help`.
- **Costs**: `memory/metrics/sessions.csv` has one row per session;
  `python tools/v2/cost_report.py` or `/costs` roll it up.
- **Memory**: `memory/MEMORY.md` is the durable index; session journals live
  in `memory/sessions/`; `python tools/v2/recall.py search "<q>"` recalls
  across all of them.
- **Uninstall automations**: `pwsh -File scripts/register-supervisor.ps1
  -Unregister`, and set `FEATURE_*=0` in `.env`.

## Security posture (read this)

- The launch scripts run Claude Code with `--dangerously-skip-permissions`,
  and `settings.json` denies the two blocking TUI dialogs. That's what makes a
  headless Telegram-driven bot possible — the model can't stall waiting for a
  keypress, and it doesn't ask before each tool call. **Understand the
  tradeoff**: the bot can run any command on your machine. Run it on a machine
  you trust with the bot's job, keep the repo private, and read
  `.claude/rules/security.md`.
- All external content (web pages, emails) is sanitized against prompt
  injection before the model reasons over it (`tools/infra/sanitize.py`), and
  memory channels are re-sanitized before injection at session start.
- Secrets live in `.env`/`credentials.json`/`token.json` — all gitignored.
  Keep secrets out of `memory/` (it's committed by design).

## Troubleshooting

- **Bot doesn't receive Telegram messages but can send** — the single-poller
  invariant was violated (a second instance stole the getUpdates slot). Close
  duplicates and relaunch, or let the supervisor heal it. See
  `.claude/rules/telegram.md`.
- **Telegram auth 401 right after setup** — the plugin's `.env` had CRLF line
  endings. Re-run setup (it writes LF-only) or re-launch (launch.ps1 rewrites
  it).
- **`--continue` shows a blocking "resume from summary" picker** — aged
  session. Start fresh (`launch --fresh`); journal/timeline restore context.
- **Google tools fail** — `FEATURE_GOOGLE=1`? `credentials.json` present?
  First call opens a browser for OAuth; `token.json` then auto-refreshes.
