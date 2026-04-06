# 🦆 Personal AI Assistant — Claude Code Scaffold

> **Your own AI executive assistant that manages your calendar, email, Slack, tasks, code, browser, and life.**

Built by [XNDR](https://xndr.io) and GooseBot — a human-AI partnership that proves what's possible when you give Claude Code full autonomy.

---

## What Is This?

A ready-to-clone scaffold that gives you a fully configured AI assistant in 30 minutes. Not a chatbot — an actual assistant that:

- Reads your calendar and preps you for meetings
- Scans your email and flags what matters
- Monitors Slack and tells you who needs what
- Tracks your to-do list and keeps it updated
- Browses the web, fills forms, takes screenshots
- Writes code, builds tools, deploys apps
- Remembers everything across sessions and computers
- Gets smarter the more you use it

**The sky is the limit.** This scaffold is the starting point — your bot evolves with you.

---

## Quick Start

### 1. Clone it
```bash
git clone https://github.com/mrcsXndr/unnamed-bot.git my-bot
cd my-bot
```

### 2. Launch it
```bash
claude --dangerously-skip-permissions
```

### 3. Set it up
```
/setup
```

The bot walks you through everything — who you are, what you need, which services to connect. Takes ~30 minutes for a full setup.

---

## One-Click Launch (No Terminal Needed)

### Windows
Create a desktop shortcut or add to PowerShell profile (`$PROFILE`):

```powershell
# Add this to your PowerShell profile
function mybot {
    $repo = "C:\Users\$env:USERNAME\Code\my-bot"
    if (-not (Test-Path $repo)) {
        Write-Host "Cloning bot..." -ForegroundColor Cyan
        git clone https://github.com/mrcsXndr/unnamed-bot.git $repo
    }
    # Auto-sync settings from cloud backup
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    if ((Test-Path "$repo\tools\sync_settings.sh") -and (Test-Path $gitBash)) {
        & $gitBash "$repo\tools\sync_settings.sh" pull 2>$null
    }
    Set-Location $repo
    claude --dangerously-skip-permissions --continue $args
}
Set-Alias -Name mb -Value mybot
```

Then just type `mybot` or `mb` in any PowerShell window.

**Desktop shortcut:** Create a `.bat` file on your desktop:
```batch
@echo off
cd /d "C:\Users\%USERNAME%\Code\my-bot"
claude --dangerously-skip-permissions --continue
```

### Mac / Linux
Add to `~/.zshrc` or `~/.bashrc`:

```bash
mybot() {
    REPO="$HOME/Code/my-bot"
    [ ! -d "$REPO" ] && git clone https://github.com/mrcsXndr/unnamed-bot.git "$REPO"
    # Auto-sync from cloud backup
    [ -n "${SYNC_DRIVE_PATH:-}" ] && bash "$REPO/tools/sync_settings.sh" pull 2>/dev/null
    cd "$REPO"
    claude --dangerously-skip-permissions --continue "$@"
}
alias mb="mybot"
```

Then just type `mybot` or `mb` in any terminal.

---

## What Do Those Flags Mean?

| Flag | What it does |
|------|-------------|
| `--dangerously-skip-permissions` | Gives the bot full autonomy — no permission prompts for file edits, terminal commands, or tool use. **You trust your bot.** |
| `--continue` | Resumes your last conversation instead of starting fresh. Your bot remembers what you were working on. |

> **Note:** The "dangerously" in the flag name is a safety disclaimer from Anthropic. In practice, your bot follows the rules in `CLAUDE.md` and `.claude/rules/` — it won't delete your files or send emails without asking first (unless you tell it to). The flag just removes the constant "are you sure?" prompts that break the flow.

---

## What's Inside

```
├── CLAUDE.md              ← Bot personality + rules (the "soul file")
├── .claude/
│   ├── settings.json      ← Hooks, env vars, permissions
│   ├── rules/             ← Behavior rules (identity, tools, security)
│   ├── commands/          ← Slash commands (/morning, /eod, /setup)
│   └── hooks/             ← Auto-runs on session start/stop
├── tools/
│   ├── google_workspace.py ← Google API (Calendar, Gmail, Tasks, Sheets, Drive)
│   ├── slack.sh            ← Slack channel/DM scanner
│   ├── sync_settings.sh    ← Multi-machine sync (Drive, USB, any cloud)
│   └── statusline.js       ← Status bar with API cost tracking
├── context/               ← Your context docs (auto-maintained by the bot)
└── .env.example           ← Environment variables template
```

## Slash Commands

| Command | What it does |
|---------|-------------|
| `/setup` | Guided setup wizard — identity, compliance, services, sync |
| `/morning` | Daily briefing — calendar, email, tasks, Slack |
| `/eod` | End-of-day wrap-up — save context, prep tomorrow |
| `/update-context` | Refresh all context docs from current state |

## Multi-Machine Sync

Your bot syncs settings, secrets, and memories between computers:

```bash
# Supported sync targets:
# - Google Drive (recommended — automatic)
# - USB stick (manual — works offline)
# - Dropbox, OneDrive, any mounted folder

# Set your sync path:
export SYNC_DRIVE_PATH="/path/to/your/cloud/backup"

# Manual sync:
bash tools/sync_settings.sh push   # Upload to cloud
bash tools/sync_settings.sh pull   # Download from cloud
bash tools/sync_settings.sh status # Check what's different

# Auto-sync is built in:
# - Session start → auto-pulls latest
# - Session stop → auto-pushes changes
```

## Session Intelligence

Your bot has a background agent that runs on every session stop:
- Summarizes what was accomplished
- Updates context docs if anything meaningful changed
- Keeps memories fresh across sessions
- Syncs everything to your cloud backup

**Recommended model:** Claude Opus 4.6 with high effort thinking enabled. This is the most capable model and makes a massive difference for an assistant that needs to reason about your work, codebase, and decisions.

---

## Services You Can Connect

All optional. Add incrementally — start with what you need.

| Service | What it enables | Free? |
|---------|----------------|-------|
| **Google Workspace** | Calendar, email, tasks, docs, files | Yes |
| **Slack** | Channel monitoring, DM scanning, search | Yes |
| **GitHub** | Code backup, version control, collaboration | Yes |
| **Cloudflare** | Deploy custom web apps, databases, file storage | Yes (generous free tier) |
| **GitLab** | Issue tracking, merge requests, CI/CD | Yes |
| **Resend** | Send emails as your bot | Yes (100/day free) |
| **Chrome Extension** | Browser automation, web scraping, form filling | Yes |
| **Figma** | Read designs, implement UI from mockups | With subscription |

---

## Privacy & Compliance

The `/setup` wizard includes a compliance assessment:
- If you handle customer data → recommends limited email scanning
- If you manage employees → advises on Slack access boundaries
- If you're in a regulated industry → suggests legal review first
- Your choice is saved and respected in all future sessions

**Your data stays local.** The bot runs on your machine. Conversations go to Anthropic's API (same as using Claude normally). Secrets never leave your `.env` file.

---

## Made With

Built by **[XNDR](https://xndr.io)** and **GooseBot** (Claude Opus 4.6) — over multiple marathon sessions spanning days of continuous development. GooseBot is XNDR's personal AI assistant built on this same scaffold, managing everything from casino platform development to Venezuela market launches to Kindle library management.

If a single human-AI team can build this in a week, imagine what yours can do.

---

## License

MIT — use it, fork it, make it yours. That's the point.
