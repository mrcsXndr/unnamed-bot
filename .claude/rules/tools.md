# Tool Execution Rules

## CRITICAL: Human-in-the-middle for external writes
- **ALWAYS ask for confirmation before writing/modifying** any Google Workspace data: Calendar events, Gmail (send/modify), Tasks (add/complete), Sheets (update/append), Drive (upload/delete)
- Read operations are fine without confirmation
- This applies to ALL external systems — never modify live data without explicit approval
- (Asking = a non-blocking Telegram question via `tg_send.py`, never a TUI dialog — see CLAUDE.md rule on blocked dialogs.)

## CLI-first, MCP where it adds value
- Prefer `tools/*` CLI wrappers over MCP for Google Workspace ops (less context usage)
- Use `tools/browser/ab.sh` (agent-browser, isolated Chrome) for ALL browser control — see `.claude/rules/browser.md`

## Layout
```
tools/
  v2/        journal, timeline, recall, commitments, cost meter, critic,
             tg_commands, tg_watchdog, update_restart, safe_write, ... (the v2 architecture)
  tg/        tg_send.py + media senders + transcribe.py (Telegram outbound)
  browser/   ab.sh (agent-browser wrapper)
  google/    google_workspace.py backend + calendar/gmail/gtasks/sheets/drive wrappers (OPTIONAL — FEATURE_GOOGLE)
  infra/     sanitize.py, statusline.js, memory-sync-hook.cjs, resource_monitor.ps1,
             sync_settings.sh, slack.sh, cloudflare_ops.py
```

## Available CLI tools
| Tool | Purpose | Backend |
|------|---------|---------|
| `tools/google/calendar.sh` | Google Calendar (today/tomorrow/week/next) | google_workspace.py |
| `tools/google/gmail.sh` | Gmail (priority/unread/search/recent) | google_workspace.py |
| `tools/google/gtasks.sh` | Google Tasks (list/lists/add/complete) | google_workspace.py |
| `tools/google/sheets.sh` | Google Sheets (read/update/append) | google_workspace.py |
| `tools/google/drive.sh` | Google Drive (search/recent/download/list) | google_workspace.py |
| `tools/browser/ab.sh` | Browser automation (agent-browser, isolated Chrome) | agent-browser |
| `tools/tg/tg_send.py` | Send Telegram messages (CommonMark→HTML + split + status footer) | Telegram Bot API |
| `tools/tg/transcribe.py` | Voice-to-text (Groq Whisper) for Telegram voice notes | Groq API |
| `tools/infra/sanitize.py` | Anti-prompt-injection sanitiser for all external content | standalone |
| `tools/infra/slack.sh` | Slack (channels/dms/history/search/unread) | Slack API (xoxp token) |
| `tools/infra/cloudflare_ops.py` | Cloudflare DNS/SSL/cache management | standalone |
| `tools/infra/sync_settings.sh` | Mirror secrets to a cloud/USB folder (opt-in) | standalone |

The Google tools are OPTIONAL: if `FEATURE_GOOGLE` is 0 or `credentials.json`
is absent, skip them cleanly — don't retry or complain.

## Hooks & framework (wired in `.claude/settings.json`)
- `.claude/hooks/session-start-v2.sh` — journal/timeline/recall/commitments injection at session start
- `.claude/hooks/user-prompt-submit.sh` — TG slash-command intercept + large-paste guard
- `.claude/hooks/post-subagent.sh` — zero-LLM critic envelope per subagent return
- `tools/v2/precompact_extract.py` + `precompact_timeline.py` — pre-compaction salvage
- `tools/v2/cost_meter.py` — per-session cost row on Stop → `memory/metrics/sessions.csv`
- `tools/infra/memory-sync-hook.cjs` — pulls/pushes `memory/` to your git remote (OPT-IN: FEATURE_MEMORY_SYNC)
- `tools/infra/statusline.js` — status bar (model, git, context %, lifetime API cost)

## Direct Python usage
```bash
PYTHONIOENCODING=utf-8 python tools/google/google_workspace.py <command> [args]
```
Always set `PYTHONIOENCODING=utf-8` when calling Python on Windows.

## Secrets & Credentials
- `credentials.json` — Google OAuth client secret (only `.example` is committed)
- `token.json` — Google OAuth token (auto-refreshes)
- `.env` — bot name, Telegram token/chat id, feature flags, API keys
- **Never commit** these files (listed in `.gitignore`)
