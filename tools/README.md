# Tools

Quick reference for the CLI helpers shipped with this template. Every tool
runs on its own — pick what you need, ignore the rest. Layout:

```
tools/
  v2/        the v2 architecture (memory channels, commitments, cost, TG commands)
  tg/        Telegram outbound + voice transcription
  browser/   agent-browser wrapper (isolated Chrome)
  google/    Google Workspace (optional — FEATURE_GOOGLE)
  infra/     sanitizer, statusline, memory sync, monitors, misc integrations
```

## v2 architecture (`tools/v2/`)

| Tool | What it does |
|---|---|
| `journal.py` | Director's Journal CRUD — `new`, `append <sess> <kind> <text>`, `read` |
| `timeline.py` | Distill journal → timeline (`build <sess>`; LLM via the claude CLI, concat fallback) |
| `recall.py` | Zero-LLM FTS5 recall over all journals/timelines — `index`, `search "<q>"`, `feedback <id> helpful\|unhelpful` |
| `commitments.py` | Due-dated follow-ups — `add "<text>" [--due 2d]`, `list`, `done <id>`, `surface`, `heartbeat` |
| `cost_meter.py` / `cost_report.py` | Per-session token+USD row on Stop → `memory/metrics/sessions.csv`; rollup reporting |
| `tg_commands.py` | TG slash-command handler (`/status`, `/journal`, `/compact`, `/costs`, `/update`, …) |
| `tg_watchdog.py` | Telegram poller liveness probe + idle-gated auto-heal (used by the supervisor) |
| `update_restart.py` | `claude update` + safe detached self-restart |
| `critic.py` | Zero-LLM critic envelope writer (SubagentStop hook) |
| `safe_write.py` | Lock + atomic-rename file writes for shared stores |
| `sanitize_chunk.py` | Injection gate for memory chunks injected at session start |
| `status_footer.py` | The one-line status footer (cwd, git, session, ctx %, TG health) |
| `precompact_extract.py` / `precompact_timeline.py` | PreCompact salvage of durable insights |

Always run with `PYTHONIOENCODING=utf-8` on Windows.

## Telegram (`tools/tg/`)

Needs `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` in `.env` (setup wizard writes them).

```bash
# CommonMark → Telegram HTML, 4000-char split, auto status footer
python tools/tg/tg_send.py "**Hello** with \`code\`"
python tools/tg/tg_send.py --reply-to 540 "threaded follow-up"
python tools/tg/tg_send.py --no-status --plain "raw text"

# Media
python tools/tg/tg_send_photo.py /path/img.png "caption"
python tools/tg/tg_send_document.py /path/file.pdf "caption"
python tools/tg/tg_send_video.py /path/clip.mp4 "caption"

# Voice note → text (needs GROQ_API_KEY)
python tools/tg/transcribe.py /path/note.oga
```

## Browser (`tools/browser/ab.sh`)

agent-browser drives an isolated Chrome for Testing — never your real Chrome.
One-time install: `npm i -g agent-browser && agent-browser install`.

```bash
tools/browser/ab.sh open  https://example.com
tools/browser/ab.sh read  https://example.com     # page text, auto-sanitized
tools/browser/ab.sh shot  /tmp/page.png https://example.com
tools/browser/ab.sh close --all                   # ALWAYS clean up after
```

See `.claude/rules/browser.md` (including the basic-auth header gotcha).

## Google Workspace (`tools/google/` — optional)

All share `google_workspace.py` + OAuth via `credentials.json`/`token.json`
in the repo root. First run opens a browser to authorize.

| Tool | Common commands |
|---|---|
| `calendar.sh` | `today`, `tomorrow`, `week`, `next` |
| `gmail.sh` | `priority`, `unread`, `recent`, `search "<query>"` |
| `gtasks.sh` | `list`, `lists`, `add "<title>"`, `complete <id>` |
| `sheets.sh` | `read <sheet-id> <range>`, `update`, `append` |
| `drive.sh` | `search "<query>"`, `recent`, `download <id>` |

Direct: `python tools/google/google_workspace.py help`

## Infra (`tools/infra/`)

| Tool | What it does |
|---|---|
| `sanitize.py` | **Critical.** Anti-prompt-injection sanitizer — `clean`, `html`, `scan`, `pipe`. See `.claude/rules/security.md`. |
| `statusline.js` | Claude Code status bar: model, git, context %, lifetime API cost, TG health |
| `memory-sync-hook.cjs` | Push/pull `memory/` to your git remote (OPT-IN: FEATURE_MEMORY_SYNC) |
| `sync_settings.sh` | Mirror secrets to `SYNC_DRIVE_PATH` — `push` / `pull` / `status` (OPT-IN) |
| `resource_monitor.ps1` | Windows janitor: orphaned automation browsers, RAM/disk alerts (`-Clean -Tg`) |
| `slack.sh` | Slack read helpers (needs `SLACK_USER_TOKEN`) |
| `cloudflare_ops.py` | Cloudflare DNS / SSL / cache checks |
