# setup.ps1 — interactive-but-scriptable bootstrap wizard (Windows).
#
# Gets you from a fresh clone to a runnable bot:
#   1. Checks prerequisites (claude, python, node, git).
#   2. Copies .env.example -> .env (if missing).
#   3. Prompts for the ONLY required inputs: bot name, Telegram bot token,
#      Telegram chat id. (Telegram can be skipped — terminal-only bot.)
#   4. Initializes the memory dirs + the cross-session recall DB.
#   5. Wires the Telegram channel plugin and prints pairing instructions.
#   6. Offers every automation as a yes/no OPT-IN (feature flags in .env):
#      Google Workspace, memory git sync, auto-commit, session debrief,
#      secrets backup, resource monitors, and the Windows supervisor /
#      TG-watchdog scheduled tasks. NOTHING GitHub-, backup-, or scheduled-
#      task-related is enabled unless you say yes.
#
# Idempotent: safe to re-run any time; it updates .env in place.
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File scripts\setup.ps1
#   pwsh -File scripts\setup.ps1 -Help
#   pwsh -File scripts\setup.ps1 -DryRun          # print, change nothing
#   pwsh -File scripts\setup.ps1 -Yes             # accept defaults (opt-ins OFF)
#   pwsh -File scripts\setup.ps1 -BotName X -TgToken T -TgChatId C -Yes

param(
    [switch]$Help,
    [switch]$DryRun,
    [switch]$Yes,
    [string]$BotName = '',
    [string]$TgToken = '',
    [string]$TgChatId = ''
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if ($Help) {
    foreach ($line in Get-Content $PSCommandPath -TotalCount 40) {
        if ($line -notmatch '^#') { break }
        Write-Output ($line -replace '^#\s?', '')
    }
    exit 0
}

function Say  { param([string]$m) Write-Host $m }
function Note { param([string]$m) Write-Host "  $m" -ForegroundColor DarkGray }

function Ask {
    param([string]$Prompt, [string]$Default = '')
    if ($Yes) { return $Default }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    $val = Read-Host "  $Prompt$suffix"
    if (-not $val) { return $Default }
    return $val
}

function AskYN {
    # Default is always NO (opt-in).
    param([string]$Prompt)
    if ($Yes) { return $false }
    $ans = Read-Host "  $Prompt [y/N]"
    return ($ans -match '^(y|yes)$')
}

function Set-DotEnv {
    # Idempotent upsert into .env. Writes LF-only, no BOM (bun + bash both
    # choke on CRLF/BOM'd .env files).
    param([string]$Key, [string]$Value)
    if ($DryRun) { Note "(dry-run) would set $Key=$Value"; return }
    $envPath = Join-Path $repo '.env'
    $lines = @()
    if (Test-Path $envPath) { $lines = @(Get-Content $envPath) }
    $found = $false
    $lines = $lines | ForEach-Object {
        if ($_ -match "^$([regex]::Escape($Key))=") { $found = $true; "$Key=$Value" } else { $_ }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    [IO.File]::WriteAllText($envPath, (($lines -join "`n") + "`n"))
}

Say ''
Say '=== Bot setup wizard ==='
Say ''

# --- 1. prerequisites --------------------------------------------------------
Say '[1/6] Checking prerequisites'
$missing = $false
foreach ($tool in @('claude', 'python', 'node', 'git')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = ''
        try { $ver = (& $tool --version 2>$null | Select-Object -First 1) } catch {}
        Note "ok: $tool ($ver)"
    } else {
        Note "MISSING: $tool"
        $missing = $true
    }
}
if ($missing) {
    Note ''
    Note "Install what's missing first:"
    Note '  claude  -> https://claude.com/claude-code'
    Note '  python  -> https://python.org (3.10+)'
    Note '  node    -> https://nodejs.org'
    Note '  git     -> https://git-scm.com'
    if (-not $DryRun) { exit 1 }
}

# --- 2. .env -------------------------------------------------------------------
Say ''
Say '[2/6] Config file (.env)'
if (-not (Test-Path '.env')) {
    if ($DryRun) { Note '(dry-run) would copy .env.example -> .env' }
    else {
        # LF-only copy (see Set-DotEnv note).
        $raw = (Get-Content '.env.example' -Raw) -replace "`r`n", "`n"
        [IO.File]::WriteAllText((Join-Path $repo '.env'), $raw)
        Note 'created .env from .env.example'
    }
} else {
    Note '.env already exists — keeping it (values you enter below overwrite in place)'
}

# --- 3. required inputs ---------------------------------------------------------
Say ''
Say '[3/6] The three required inputs'
if (-not $BotName) { $BotName = Ask 'What is your bot called?' 'my-bot' }
Set-DotEnv 'BOT_NAME' $BotName

if (-not $TgToken -and -not $Yes) {
    Note 'Telegram: create a bot with @BotFather (https://t.me/BotFather) and paste'
    Note 'its token here. Leave blank to skip Telegram (terminal-only bot).'
    $TgToken = Ask 'Telegram bot token' ''
}
if ($TgToken) {
    Set-DotEnv 'TELEGRAM_BOT_TOKEN' $TgToken
    if (-not $TgChatId -and -not $Yes) {
        Note 'Chat id: message your new bot once, then open'
        Note '  https://api.telegram.org/bot<TOKEN>/getUpdates'
        Note 'and read "chat":{"id":...}.'
        $TgChatId = Ask 'Your Telegram chat id' ''
    }
    if ($TgChatId) { Set-DotEnv 'TELEGRAM_CHAT_ID' $TgChatId }
} else {
    Note 'skipping Telegram — you can re-run setup later to add it'
}

# --- 4. memory dirs + recall DB ---------------------------------------------------
Say ''
Say '[4/6] Memory + recall index'
if ($DryRun) {
    Note '(dry-run) would create memory/sessions, memory/metrics + recall DB'
} else {
    foreach ($d in @('memory\sessions', 'memory\metrics')) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    $env:PYTHONIOENCODING = 'utf-8'
    & python tools\v2\recall.py index *> $null
    if ($LASTEXITCODE -eq 0) { Note 'recall index initialized (memory/index/recall.db)' }
    else { Note 'recall index init failed (non-fatal; it retries at session start)' }
}

# --- 5. Telegram channel plugin -----------------------------------------------------
Say ''
Say '[5/6] Telegram channel'
if ($TgToken) {
    $tgDir = "$env:USERPROFILE\.claude\channels\telegram"
    if ($DryRun) { Note "(dry-run) would write token to $tgDir\.env" }
    else {
        if (-not (Test-Path $tgDir)) { New-Item -ItemType Directory -Force -Path $tgDir | Out-Null }
        # LF-only: the plugin's bun runtime reads a trailing CRLF into the
        # token, which then fails Telegram auth with a confusing 401.
        [IO.File]::WriteAllText("$tgDir\.env", "TELEGRAM_BOT_TOKEN=$TgToken`n")
        Note "token written to $tgDir\.env"
    }
    Note ''
    Note 'To pair your Telegram account (one-time):'
    Note '  1. Launch the bot:   pwsh -File scripts\launch.ps1'
    Note '  2. Message your bot on Telegram — it replies with a pairing code'
    Note '  3. In the Claude Code terminal run:  /telegram:access pair <code>'
} else {
    Note 'skipped (no token)'
}

# --- 6. opt-in features ---------------------------------------------------------------
Say ''
Say '[6/6] Optional automations (all OFF unless you opt in)'

if (AskYN 'Enable Google Workspace tools (calendar/gmail/tasks/sheets/drive)?') {
    Set-DotEnv 'FEATURE_GOOGLE' '1'
    Note '-> FEATURE_GOOGLE=1. Finish OAuth:'
    Note '   1. Create an OAuth client (Desktop) at https://console.cloud.google.com'
    Note '      and enable the Calendar/Gmail/Tasks/Sheets/Drive APIs'
    Note '   2. Save it as credentials.json in the repo root (see credentials.json.example)'
    Note '   3. Run: python tools\google\google_workspace.py help  (first call opens a browser)'
} else {
    Set-DotEnv 'FEATURE_GOOGLE' '0'
    Note '-> Google tools off (the bot skips them cleanly)'
}

if (AskYN 'Sync memory/ to your git remote automatically (commit+push on stop)?') {
    Set-DotEnv 'FEATURE_MEMORY_SYNC' '1'
} else { Set-DotEnv 'FEATURE_MEMORY_SYNC' '0' }

if (AskYN 'Auto-commit ALL repo changes locally on session stop?') {
    Set-DotEnv 'FEATURE_AUTO_COMMIT' '1'
} else { Set-DotEnv 'FEATURE_AUTO_COMMIT' '0' }

if (AskYN 'Background LLM session debrief on stop (costs tokens)?') {
    Set-DotEnv 'FEATURE_SESSION_DEBRIEF' '1'
} else { Set-DotEnv 'FEATURE_SESSION_DEBRIEF' '0' }

if (AskYN 'Mirror secrets to a cloud/USB backup folder?') {
    $syncPath = Ask 'Backup folder path' ''
    if ($syncPath) {
        Set-DotEnv 'FEATURE_SECRETS_BACKUP' '1'
        Set-DotEnv 'SYNC_DRIVE_PATH' $syncPath
    } else {
        Note 'no path given — leaving backups off'
        Set-DotEnv 'FEATURE_SECRETS_BACKUP' '0'
    }
} else { Set-DotEnv 'FEATURE_SECRETS_BACKUP' '0' }

# --- Windows-only: supervisor + watchdog scheduled tasks -------------------------------
Say ''
Say 'Windows resilience layer (scheduled tasks — all opt-in):'
Note 'The SUPERVISOR keeps exactly one healthy bot running: cold-starts it at'
Note 'logon/after a crash, heals a dead Telegram poller, surfaces due'
Note 'commitments, and (optionally) runs hourly resource monitors.'
if (AskYN 'Install the supervisor scheduled task (at-logon + every 3 min)?') {
    if ($DryRun) { Note '(dry-run) would run scripts\register-supervisor.ps1' }
    else { & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\register-supervisor.ps1') }
    if (AskYN 'Also enable the hourly resource janitor inside supervisor ticks?') {
        Set-DotEnv 'FEATURE_MONITORS' '1'
    } else { Set-DotEnv 'FEATURE_MONITORS' '0' }
} else {
    Set-DotEnv 'FEATURE_MONITORS' '0'
    Note 'skipped. Install later with: pwsh -File scripts\register-supervisor.ps1'
    if (AskYN 'Install ONLY the standalone TG-poller watchdog instead?') {
        if ($DryRun) { Note '(dry-run) would run scripts\register-tg-watchdog.ps1 -Confirm' }
        else { & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\register-tg-watchdog.ps1') -Confirm }
    }
}

Say ''
Say '=== Done. Launch with:  pwsh -File scripts\launch.ps1 ==='
Say '    (then message your Telegram bot, or just talk in the terminal)'
exit 0
