# setup.ps1 — interactive-but-scriptable bootstrap wizard (Windows).
#
# Gets you from a fresh clone to a runnable bot:
#   1. Installs missing dependencies (scripts\install_deps.ps1 — Claude Code
#      CLI + PATH, Node.js, Python 3, pnpm, agent-browser, git; winget
#      preferred, scoop/choco fallback). Per-component opt-in; already-
#      installed tools are detected and skipped.
#   2. Copies .env.example -> .env (if missing).
#   3. Prompts for the ONLY required inputs: bot name, Telegram bot token,
#      Telegram chat id. The token is validated against the Telegram API and
#      the chat id can be AUTO-DETECTED (just message your bot once).
#      (Telegram can be skipped — terminal-only bot.)
#   4. Initializes the memory dirs + the cross-session recall DB.
#   5. Wires the Telegram channel plugin and PRE-AUTHORIZES your chat id
#      (no pairing dance needed).
#   6. Offers every automation as a yes/no OPT-IN (feature flags in .env):
#      Google Workspace, memory git sync, auto-commit, session debrief,
#      secrets backup, resource monitors, and the Windows supervisor /
#      TG-watchdog scheduled tasks. NOTHING GitHub-, backup-, or scheduled-
#      task-related is enabled unless you say yes.
#   7. Sets up EASY LAUNCH: installs a one-word `bot` command into your
#      PowerShell profile + creates Desktop/Start-Menu shortcuts (double-click
#      to start — no CLI needed).
#   8. Runs the bundled self-check (scripts\smoke_test.ps1) and prints the
#      exact launch command.
#
# Idempotent: safe to re-run any time; it updates .env in place.
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File scripts\setup.ps1
#   pwsh -File scripts\setup.ps1 -Help
#   pwsh -File scripts\setup.ps1 -DryRun          # print, change nothing
#   pwsh -File scripts\setup.ps1 -Yes             # accept defaults (installs
#                                                 #   missing deps, opt-ins OFF)
#   pwsh -File scripts\setup.ps1 -SkipInstall     # skip the dependency installer
#   pwsh -File scripts\setup.ps1 -BotName X -TgToken T -TgChatId C -Yes

param(
    [switch]$Help,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$SkipInstall,
    [string]$BotName = '',
    [string]$TgToken = '',
    [string]$TgChatId = ''
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if ($Help) {
    foreach ($line in Get-Content $PSCommandPath -TotalCount 45) {
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

function AskYNYes {
    # Default YES — only for non-automation steps like the self-check; the
    # opt-in automations always go through AskYN above.
    param([string]$Prompt)
    if ($Yes) { return $true }
    $ans = Read-Host "  $Prompt [Y/n]"
    return -not ($ans -match '^(n|no)$')
}

function Test-TgToken {
    # Returns the bot's @username on success, 'INVALID' on a definitive
    # rejection, $null when the check couldn't run (network etc — don't block).
    param([string]$Token)
    try {
        $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/getMe" -TimeoutSec 10
        if ($r.ok) { return [string]$r.result.username }
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -eq 401 -or $status -eq 404) { return 'INVALID' }
    }
    return $null
}

function Get-TgChatId {
    # Chat id of the most recent DM to the bot; $null when none/unreachable.
    param([string]$Token)
    try {
        $r = Invoke-RestMethod -Uri "https://api.telegram.org/bot$Token/getUpdates" -TimeoutSec 10
        if ($r.ok) {
            $ids = @($r.result | Where-Object { $_.message } | ForEach-Object { $_.message.chat.id })
            if ($ids.Count -gt 0) { return [string]$ids[-1] }
        }
    } catch {}
    return $null
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

# --- 1. dependencies (detect + offer to install what's missing) ---------------
Say '[1/8] Dependencies'
if ($SkipInstall) {
    Note 'installer skipped (-SkipInstall)'
} else {
    $depArgs = @()
    if ($DryRun) { $depArgs += '-DryRun' }
    if ($Yes)    { $depArgs += '-Yes' }
    # in-process call (works under both powershell 5 and pwsh 7)
    try { & (Join-Path $repo 'scripts\install_deps.ps1') @depArgs } catch { Note "installer error: $($_.Exception.Message)" }
}

# Re-verify the required four; without them the bot cannot launch.
$missing = $false
foreach ($tool in @('claude', 'python', 'node', 'git')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    $ver = ''
    if ($cmd) { try { $ver = (& $tool --version 2>$null | Select-Object -First 1) } catch {} }
    if ($cmd -and ($tool -ne 'python' -or $ver)) {
        Note "ok: $tool ($ver)"
    } else {
        Note "MISSING: $tool"
        $missing = $true
    }
}
if ($missing) {
    Note ''
    Note 'Required tools are still missing. If they were JUST installed, open a'
    Note 'NEW terminal and re-run this wizard. Manual installs:'
    Note '  claude  -> https://claude.com/claude-code'
    Note '  python  -> https://python.org (3.10+)'
    Note '  node    -> https://nodejs.org'
    Note '  git     -> https://git-scm.com'
    if (-not $DryRun) { exit 1 }
}

# --- 2. .env -------------------------------------------------------------------
Say ''
Say '[2/8] Config file (.env)'
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
Say '[3/8] The three required inputs'
if (-not $BotName) { $BotName = Ask 'What is your bot called?' 'my-bot' }
Set-DotEnv 'BOT_NAME' $BotName

if (-not $TgToken -and -not $Yes) {
    Note 'Telegram: create a bot with @BotFather (https://t.me/BotFather) and paste'
    Note 'its token here. Leave blank to skip Telegram (terminal-only bot).'
    $TgToken = Ask 'Telegram bot token' ''
}
if ($TgToken) {
    $botUser = Test-TgToken $TgToken
    if ($botUser -eq 'INVALID') {
        Note 'WARNING: Telegram rejected that token. Double-check it with @BotFather.'
        Note 'Continuing anyway — re-run setup to fix it.'
    } elseif ($botUser) {
        Note "token OK — your bot is @$botUser"
    }
    Set-DotEnv 'TELEGRAM_BOT_TOKEN' $TgToken

    # chat id: auto-detect from the bot's inbox when possible
    if (-not $TgChatId) {
        $TgChatId = Get-TgChatId $TgToken
        if ($TgChatId) { Note "auto-detected your chat id: $TgChatId (from your last message to the bot)" }
    }
    if (-not $TgChatId -and -not $Yes) {
        Note 'Send your bot ANY message on Telegram now, then press Enter to'
        Note 'auto-detect your chat id — or type the id manually.'
        $TgChatId = Ask 'Telegram chat id (blank = auto-detect)' ''
        if (-not $TgChatId) {
            $TgChatId = Get-TgChatId $TgToken
            if ($TgChatId) { Note "auto-detected: $TgChatId" }
        }
    }
    if ($TgChatId) {
        Set-DotEnv 'TELEGRAM_CHAT_ID' $TgChatId
    } else {
        Note "no chat id yet — the bot can't message you first; re-run setup after"
        Note 'messaging your bot once, or set TELEGRAM_CHAT_ID in .env by hand.'
    }
} else {
    Note 'skipping Telegram — you can re-run setup later to add it'
}

# --- 4. memory dirs + recall DB ---------------------------------------------------
Say ''
Say '[4/8] Memory + recall index'
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
Say '[5/8] Telegram channel'
$prePaired = $false
if ($TgToken) {
    $tgDir = "$env:USERPROFILE\.claude\channels\telegram"
    if ($DryRun) {
        Note "(dry-run) would write token to $tgDir\.env"
        if ($TgChatId) { Note "(dry-run) would pre-authorize chat id $TgChatId (tools\tg\tg_pair.py)" }
    }
    else {
        if (-not (Test-Path $tgDir)) { New-Item -ItemType Directory -Force -Path $tgDir | Out-Null }
        # LF-only: the plugin's bun runtime reads a trailing CRLF into the
        # token, which then fails Telegram auth with a confusing 401.
        [IO.File]::WriteAllText("$tgDir\.env", "TELEGRAM_BOT_TOKEN=$TgToken`n")
        Note "token written to $tgDir\.env"
        # Pre-authorize the owner's chat id -> no pairing dance on first message.
        if ($TgChatId) {
            $env:PYTHONIOENCODING = 'utf-8'
            & python (Join-Path $repo 'tools\tg\tg_pair.py') $TgChatId *> $null
            if ($LASTEXITCODE -eq 0) {
                $prePaired = $true
                Note "chat id $TgChatId pre-authorized — no pairing step needed"
            }
        }
    }
    if (-not $prePaired) {
        Note ''
        Note 'To pair your Telegram account (one-time):'
        Note '  1. Launch the bot:   pwsh -File scripts\launch.ps1'
        Note '  2. Message your bot on Telegram — it replies with a pairing code'
        Note '  3. In the Claude Code terminal run:  /telegram:access pair <code>'
    }
} else {
    Note 'skipped (no token)'
}

# --- 6. opt-in features ---------------------------------------------------------------
Say ''
Say '[6/8] Optional automations (all OFF unless you opt in)'

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

# --- 7. easy launch: profile command + desktop shortcuts ------------------------------
Say ''
Say '[7/8] Easy launch (so you never need the CLI)'
Note 'A one-word command + double-click shortcuts to start the bot.'
if (AskYNYes 'Add a `bot` command to your PowerShell profile?') {
    # HASHTABLE splat (not array): an array element '-DryRun' is bound as a
    # POSITIONAL arg, not the switch — it would silently defeat -DryRun.
    $ip = @{}; if ($DryRun) { $ip['DryRun'] = $true }
    try { & (Join-Path $repo 'scripts\install_profile.ps1') @ip } catch { Note "profile install error: $($_.Exception.Message)" }
} else {
    Note 'skipped. Add later with: pwsh -File scripts\install_profile.ps1'
}
if (AskYNYes 'Create Desktop + Start Menu shortcuts (double-click to launch)?') {
    $cs = @{}; if ($DryRun) { $cs['DryRun'] = $true }
    if ($BotName) { $cs['BotName'] = $BotName }
    try { & (Join-Path $repo 'scripts\create_shortcuts.ps1') @cs } catch { Note "shortcut error: $($_.Exception.Message)" }
} else {
    Note 'skipped. Create later with: pwsh -File scripts\create_shortcuts.ps1'
}

# --- 8. self-check + next step ----------------------------------------------------------
Say ''
Say '[8/8] Self-check'
if ($DryRun) {
    Note '(dry-run) would run scripts\smoke_test.ps1'
} elseif (AskYNYes 'Run the self-check now (verifies the harness, ~30s)?') {
    & (Join-Path $repo 'scripts\smoke_test.ps1')
    if ($LASTEXITCODE -eq 0) {
        Note 'self-check PASSED'
    } else {
        Note 'some self-check items failed (see above) — the bot may still launch;'
        Note 're-run anytime with: pwsh -File scripts\smoke_test.ps1'
    }
} else {
    Note 'skipped. Run anytime with: pwsh -File scripts\smoke_test.ps1'
}

Say ''
Say '=== Setup complete ==='
Say ''
$startLabel = if ($BotName) { $BotName } else { 'your bot' }
Say 'NEXT STEP — start your bot any of these ways (easiest first):'
Say ''
Say "    1. Double-click the `"$startLabel`" shortcut on your Desktop"
Say '    2. Type   bot   in a NEW PowerShell window'
Say '    3. Or run:  pwsh -File scripts\launch.ps1'
Say ''
if ($TgToken) {
    if ($prePaired) {
        Say 'Then message your bot on Telegram — your chat id is already authorized,'
        Say 'so it will answer right away. (Or just talk in the terminal.)'
    } else {
        Say 'Then message your bot on Telegram and pair once with'
        Say '/telegram:access pair <code>. (Or just talk in the terminal.)'
    }
} else {
    Say 'Talk to it in the terminal. Re-run this wizard anytime to add Telegram.'
}
exit 0
