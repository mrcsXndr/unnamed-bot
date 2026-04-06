# Personal Assistant Bot — Claude Code Scaffold

A ready-to-go personal AI assistant powered by Claude Code. Manages your calendar, email, tasks, Slack, and projects with full Google Workspace and GitLab integration.

## Quick Start

1. **Clone this repo** to your machine
2. **Copy** `.env.example` → `.env`
3. **Run** `claude` in this directory
4. **Type** `/setup` — the bot walks you through everything

## What You Get

- **/morning** — Daily briefing (calendar, email, tasks, Slack)
- **/eod** — End-of-day wrap-up and context save
- **/update-context** — Refresh all context docs
- **/setup** — Guided setup wizard with compliance checks
- **Task Board** — Google Sheet with checkboxes, priorities, auto-tracking
- **Multi-machine sync** — Secrets and settings sync via Google Drive
- **Memory system** — Persistent memory across sessions, synced between computers
- **Cost tracking** — Real API cost estimate in the status line
- **Session hooks** — Auto-inject context on start, auto-commit on stop

## Setup Requirements

- [Claude Code](https://claude.ai/code) installed
- Python 3.10+ (for Google Workspace tools)
- Git Bash (Windows) or bash (Mac/Linux)
- Google Cloud project with OAuth credentials
- Optional: Slack workspace, GitLab account, Resend account

## Architecture

```
├── CLAUDE.md              ← Bot personality + rules (the "soul file")
├── .claude/
│   ├── settings.json      ← Hooks, env vars, permissions
│   ├── rules/             ← Behavior rules (identity, tools, security)
│   ├── commands/           ← Slash commands (/morning, /eod, /setup)
│   ├── hooks/             ← Session start/stop automation
│   └── skills/            ← Custom skills
├── tools/
│   ├── google_workspace.py ← Google API backend (Calendar, Gmail, Tasks, Sheets, Drive)
│   ├── calendar.sh         ← Calendar CLI wrapper
│   ├── gmail.sh            ← Gmail CLI wrapper
│   ├── gtasks.sh           ← Tasks CLI wrapper
│   ├── sheets.sh           ← Sheets CLI wrapper
│   ├── drive.sh            ← Drive CLI wrapper
│   ├── slack.sh            ← Slack CLI wrapper
│   ├── sync_settings.sh    ← Multi-machine settings sync via Google Drive
│   └── statusline.js       ← Status bar with API cost tracking
├── context/               ← Project context docs (auto-maintained)
├── templates/             ← Document templates
├── .env.example           ← Environment variables template
└── .gitignore             ← Keeps secrets out of git
```

## Multi-Machine Setup

Settings and secrets sync via Google Drive:
```bash
# On your main machine (push settings)
bash tools/sync_settings.sh push

# On another machine (pull settings)
bash tools/sync_settings.sh pull
```

## PowerShell Quick Launch

Add to your PowerShell profile (`$PROFILE`):
```powershell
function mybot {
    $repo = "C:\path\to\this-repo"
    if (-not (Test-Path $repo)) {
        Write-Host "Cloning bot..." -ForegroundColor Cyan
        git clone <your-repo-url> $repo
    }
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    if ((Test-Path "$repo\tools\sync_settings.sh") -and (Test-Path $gitBash)) {
        & $gitBash "$repo\tools\sync_settings.sh" pull 2>$null
    }
    Set-Location $repo
    claude --dangerously-skip-permissions --continue $args
}
Set-Alias -Name mb -Value mybot
```

## Compliance

The `/setup` wizard assesses your role and data access needs before enabling integrations. If you manage customer or employee data, it recommends appropriate access levels to stay compliant with GDPR, employment law, and industry regulations.

## License

Private — not for redistribution.
