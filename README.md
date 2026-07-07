# Your Bot — a Claude Code personal-assistant template (v2)

> **Clone it, run `setup`, message your own Telegram bot in minutes.** A
> production-grade harness for running [Claude Code](https://claude.com/claude-code)
> as a long-lived executive assistant, dev partner, and second brain — with
> persistent cross-session memory, a Telegram bridge, tiered subagents, cost
> metering, and an opt-in self-healing supervisor.

This is a **template**, not a product. It lives in your repo, on your machine,
with your secrets in `.env`. Ships with **zero data** — every automation is
OPT-IN, and the bot grows into whatever you need.

## 60-second quickstart

```bash
git clone <your-fork-url> my-bot && cd my-bot

# Windows                                   # macOS / Linux
pwsh -File scripts\setup.ps1                bash scripts/setup.sh
pwsh -File scripts\launch.ps1               bash scripts/launch.sh
```

Setup asks for three things — **bot name, Telegram bot token, chat id**
(token from [@BotFather](https://t.me/BotFather); skip Telegram entirely if
you just want a terminal bot). Everything else is a yes/no opt-in. Then
message your bot, pair once with `/telegram:access pair <code>`, done.

**Never want to touch a terminal again?** The wizard's *Easy launch* step (on
by default) installs a one-word `bot` command into your shell profile **and**
puts double-click **Desktop + Start-Menu shortcuts** on your machine — so
starting the long-running conversation is just typing `bot` or double-clicking
an icon. (Install them later by hand with `scripts\install_profile.ps1` and
`scripts\create_shortcuts.ps1`.)

Full walkthrough + troubleshooting: **[docs/SETUP.md](docs/SETUP.md)**.

## What makes this different from "claude in a terminal"

**1. Memory that survives.** Three context channels (borrowed from Slack's
agent-context pattern):

- a **Journal** of findings/decisions/actions appended as they happen,
- a distilled **Timeline** rebuilt from it,
- an FTS5 **recall index** over every past session (`recall.py search`) with
  trust scoring — wrong memories decay out.

Compaction stops being lossy; sessions run for days with `--continue`.

**2. A real Telegram bot.** Official channel plugin inbound; CommonMark→HTML
outbound with auto-splitting and an automatic status footer; slash commands
(`/status`, `/journal`, `/compact`, `/costs`, `/update`, …) handled by a hook
without burning main-thread context; a large-paste guard; ack-first
orchestration rules.

**3. Tiered subagents.** `planner` / `senior-coder` (opus) for the hard calls,
`coder` / `one-shot` (sonnet) for execution and lookups, a `critic` for
credibility-grading results. The main thread stays an orchestrator.

**4. Cost visibility.** Every session appends tokens + USD to
`memory/metrics/sessions.csv`; a statusline shows lifetime spend; `/costs`
rolls it up from your phone.

**5. Self-healing (opt-in, Windows).** A supervisor scheduled task keeps
exactly one healthy instance alive: cold-start at logon, heal a dead Telegram
poller, resurface due commitments, kill orphaned automation browsers. Plus a
safe self-restart flow so `/update` from your phone actually works.

**6. Security posture out of the box.** Anti-prompt-injection sanitizer on all
external content, memory-channel sanitization at session start, hard-denied
blocking dialogs, secrets kept out of git.

## Repo tour

```
CLAUDE.md              ← the bot's soul file (personalize me)
.claude/
  settings.json        ← hooks (all fail-open), dialog denies, statusline
  agents/              ← planner / senior-coder / coder / one-shot / critic
  hooks/               ← session-start, prompt-submit, post-subagent, stop hooks
  rules/               ← identity, tools, browser, telegram, security, v2-architecture, coding
  commands/, skills/   ← /critic, /morning, /eod, productivity skills
tools/
  v2/                  ← journal, timeline, recall, commitments, cost meter,
                         tg_commands, tg_watchdog, safe_write, sanitize_chunk …
  tg/                  ← tg_send.py + photo/document/video + voice transcription
  browser/ab.sh        ← agent-browser (isolated Chrome) automation
  google/              ← calendar / gmail / tasks / sheets / drive (optional)
  infra/               ← sanitize.py, statusline.js, memory-sync, monitors, slack, cloudflare
scripts/
  setup.(ps1|sh)       ← the bootstrap wizard (idempotent)
  launch.(ps1|sh)      ← one-command start (continue/fresh + TG channel wiring)
  supervisor.ps1, register-supervisor.ps1, restart-bot.ps1, register-tg-watchdog.ps1
memory/                ← the bot's long-term memory (committed on purpose; ships empty)
docs/SETUP.md          ← setup guide, feature matrix, cross-platform notes
```

## Opt-in features (all default OFF)

| Feature | How to enable |
|---|---|
| Google Workspace tools | setup wizard → `FEATURE_GOOGLE=1` + `credentials.json` |
| Memory git sync (push/pull `memory/`) | `FEATURE_MEMORY_SYNC=1` |
| Auto-commit on session stop (local only) | `FEATURE_AUTO_COMMIT=1` |
| LLM session debrief on stop | `FEATURE_SESSION_DEBRIEF=1` |
| Secrets backup to cloud/USB folder | `FEATURE_SECRETS_BACKUP=1` + `SYNC_DRIVE_PATH` |
| Supervisor / watchdog / monitors (Windows) | `scripts/register-supervisor.ps1` (+ `FEATURE_MONITORS=1`) |
| Voice-note transcription | `GROQ_API_KEY` |
| Task board `/tasks` command | `TASK_BOARD_SHEET_ID` |

Flip flags in `.env` any time; every hook checks them and no-ops when off.
Details: [docs/SETUP.md](docs/SETUP.md#opt-in-feature-matrix).

## Cross-platform

Core bot (hooks, memory channels, Telegram, browser, Google tools, cost
meter): **Windows, macOS, Linux**. The resilience layer (supervisor, watchdog,
auto-restart, resource monitor) is **Windows-only** (scheduled tasks +
PowerShell); a cron/systemd sketch for *nix is in
[docs/SETUP.md](docs/SETUP.md#cross-platform-support).

## Security note (important)

The launchers run Claude Code with `--dangerously-skip-permissions` — that's
what makes an autonomous, phone-driven bot possible, and it means the bot can
run any command on your machine. Read
[docs/SETUP.md](docs/SETUP.md#security-posture-read-this) before turning
everything on. Never commit `.env`, `credentials.json`, or `token.json`
(already gitignored), and keep secrets out of `memory/`.

## License / provenance

Template distilled from a private production bot; all personal data removed.
Use it, fork it, rename it — it's yours.
