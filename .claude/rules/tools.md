# Tool Execution Rules

## CRITICAL: Human-in-the-middle for external writes
- **ALWAYS ask for confirmation before writing/modifying** any Google Workspace data: Calendar events, Gmail (send/modify), Tasks (add/complete), Sheets (update/append), Drive (upload/delete)
- Read operations are fine without confirmation
- This applies to ALL external systems — never modify live data without explicit approval

## CLI-first, MCP where it adds value
- Prefer `tools/*.sh` CLI wrappers over MCP for Google Workspace ops (less context usage)

## Architecture
- **Backend**: `tools/google_workspace.py` — single Python module for all Google API calls
- **Shell wrappers**: thin scripts that delegate to `google_workspace.py`
- **Auth**: OAuth via `credentials.json` + `token.json` in project root
- **Scopes (full read-write)**: calendar, gmail.modify, tasks, spreadsheets, drive

## Available CLI tools
| Tool | Purpose | Backend |
|------|---------|---------|
| `tools/calendar.sh` | Google Calendar (today/tomorrow/week/next) | google_workspace.py |
| `tools/gmail.sh` | Gmail (priority/unread/search/recent) | google_workspace.py |
| `tools/gtasks.sh` | Google Tasks (list/lists/add/complete) | google_workspace.py |
| `tools/sheets.sh` | Google Sheets (read/update/append) | google_workspace.py |
| `tools/drive.sh` | Google Drive (search/recent/download/list) | google_workspace.py |
| `tools/slack.sh` | Slack (channels/dms/history/search/unread) | Slack API (xoxp token) |
| `tools/sync_settings.sh` | Sync secrets/settings between machines via Google Drive | standalone |

## Direct Python usage
For complex operations, call `google_workspace.py` directly:
```bash
PYTHONIOENCODING=utf-8 python tools/google_workspace.py <command> [args]
```
Run `google_workspace.py help` for full command list.

## Secrets & Credentials
- `credentials.json` — Google OAuth client secret
- `token.json` — Google OAuth token (auto-refreshes)
- `.env` — API keys and tokens
- **Never commit** these files (listed in `.gitignore`)
