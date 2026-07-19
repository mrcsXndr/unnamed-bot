# launch.ps1 — one-command startup for the bot on Windows.
#
# Run: pwsh -ExecutionPolicy Bypass -File scripts\launch.ps1
#   launch.ps1               # interactive Continue/Fresh menu
#   launch.ps1 -Continue     # non-interactive: resume last session
#   launch.ps1 -Fresh        # non-interactive: start a fresh session
#   launch.ps1 -Force        # bypass the duplicate-launch guard
#
# What it does:
#   1. Optionally pulls latest secrets/settings + repo (opt-in via .env flags).
#   2. Refuses to launch a duplicate if a live instance is already running.
#   3. Makes the Telegram channel plugin work on Windows (two known gotchas).
#   4. Claims the Telegram single-poller owner-lock (only ONE getUpdates
#      long-poller may exist per bot token — a second steals the slot and the
#      first 409s into a permanently dead state).
#   5. Continue-or-fresh (a one-shot .claude/.bot_fresh_restart marker from the
#      supervisor/restart flow forces FRESH — journal/timeline/recall rebuild
#      context, and it avoids Claude Code's blocking resume-from-summary
#      picker on aged sessions).
#   6. Launches Claude Code with the Telegram channel plugin attached.
#
# -Continue / -Fresh exist so a detached or scripted relaunch (supervisor,
# restart-bot.ps1) can launch hands-off with no keypress.

param(
    [switch]$Continue,
    [switch]$Fresh,
    [switch]$Force,
    # Trace tag for who initiated this launch (manual | supervisor-cold |
    # supervisor-restart). Recorded in .claude/.bot_state.json + launches.log.
    [string]$StartedBy = 'manual',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Passthrough
)

$ErrorActionPreference = 'Continue'

$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

if ($Continue -and $Fresh) {
    Write-Host "launch: -Continue and -Fresh are mutually exclusive." -ForegroundColor Red
    exit 1
}

# Read one KEY=value out of the repo .env (returns $null when missing/placeholder).
function Get-DotEnvValue {
    param([string]$Key)
    $envFile = Join-Path $repo '.env'
    if (-not (Test-Path $envFile)) { return $null }
    foreach ($line in Get-Content $envFile -ErrorAction SilentlyContinue) {
        if ($line -match "^\s*$Key\s*=\s*(.+?)\s*$") {
            $val = $matches[1].Trim('"').Trim("'")
            if ($val -and $val -notmatch 'YOUR_.*_HERE' -and $val -ne '<' ) { return $val }
        }
    }
    return $null
}
function Test-Feature { param([string]$Name) return ((Get-DotEnvValue $Name) -eq '1') }

function Test-BotPidAlive {
    param([int]$ProcId, [string[]]$Names)
    if ($ProcId -le 0) { return $false }
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($Names) { return ($Names -contains $p.ProcessName) }
    return $true
}

# Extract the first run of digits from a possibly BOM/whitespace-prefixed
# string. A UTF-8 BOM (U+FEFF) is a format char that .Trim() does NOT strip,
# so [int]::TryParse on a BOM'd line fails. Regex side-steps the BOM entirely.
function Get-FirstPid {
    param([string]$Raw)
    if ($Raw -and ($Raw -match '\d+')) { return [int]$matches[0] }
    return 0
}

# Does the given shell PID have a live claude.exe child?
function Test-HasClaudeChild {
    param([int]$ShellPid)
    if ($ShellPid -le 0) { return $false }
    try {
        $kid = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ShellPid" -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -eq 'claude.exe' } | Select-Object -First 1
        return [bool]$kid
    } catch { return $false }
}

# --- duplicate-launch guard --------------------------------------------------
# One authoritative instance at a time. Liveness-based: a stale/dead PID in
# the state never blocks. FAIL-OPEN: any error reading state => proceed.
$stateFile = Join-Path $repo '.claude\.bot_state.json'
if (-not $Force) {
    try {
        if (Test-Path $stateFile) {
            $st = Get-Content $stateFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($st) {
                $shellPid = 0; $claudePid = 0
                if ($null -ne $st.shell_pid)  { $shellPid  = [int]$st.shell_pid }
                if ($null -ne $st.claude_pid) { $claudePid = [int]$st.claude_pid }
                $shellLive  = (Test-BotPidAlive $shellPid @('pwsh','powershell')) -and (Test-HasClaudeChild $shellPid)
                $claudeLive = Test-BotPidAlive $claudePid @('claude')
                if ($shellLive -or $claudeLive) {
                    Write-Host ""
                    Write-Host "  Bot already running — refusing to launch a duplicate." -ForegroundColor Yellow
                    Write-Host "    claude_pid=$claudePid shell_pid=$shellPid (use -Force to launch anyway)" -ForegroundColor DarkGray
                    Write-Host ""
                    exit 0
                }
            }
        }
    } catch {}
}

# --- optional: back up secrets/settings + pull repo (opt-in via .env flags) ---
# Back up secrets TO the backup folder — PUSH ONLY. An auto-PULL on every
# launch can silently overwrite freshly-fixed local files with stale backup
# copies (it re-imported a local config fix for days). The backup is a BACKUP,
# not a source of truth: restore is manual/on-demand only (fresh-box DR or an
# explicit "restore from backup"):  bash tools/infra/sync_settings.sh pull
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
if ((Test-Feature 'FEATURE_SECRETS_BACKUP') -and (Test-Path "$repo\tools\infra\sync_settings.sh") -and (Test-Path $gitBash)) {
    Write-Host "Backing up settings to backup folder (push-only)..." -ForegroundColor DarkGray
    & $gitBash "$repo\tools\infra\sync_settings.sh" push 2>$null
}
if (Test-Feature 'FEATURE_MEMORY_SYNC') {
    git pull --rebase --autostash 2>$null | Out-Null
}

# --- daily Claude Code self-update check (native updater; never blocks) ------
try {
    $claudeExeUpd = "$env:USERPROFILE\.local\bin\claude.exe"
    $stampFile    = Join-Path $repo '.claude\.bot_update_stamp'
    $today        = (Get-Date).ToString('yyyy-MM-dd')
    $lastStamp    = ''
    if (Test-Path $stampFile) { $lastStamp = (Get-Content $stampFile -Raw -ErrorAction SilentlyContinue).Trim() }
    if (($lastStamp -ne $today) -and (Test-Path $claudeExeUpd)) {
        Write-Host "Checking for Claude Code update..." -ForegroundColor DarkGray
        try { & $claudeExeUpd update 2>$null | Out-Null } catch {}
        try { Set-Content -Path $stampFile -Value $today -Encoding utf8 -ErrorAction SilentlyContinue } catch {}
    }
} catch {}

# --- Telegram channel plugin: Windows fixes -----------------------------------
# These make `--channels plugin:telegram@claude-plugins-official` actually work
# on Windows. Both no-op if the plugin isn't installed or Telegram is unused.
$botToken = Get-DotEnvValue 'TELEGRAM_BOT_TOKEN'

$pluginRoot = "$env:USERPROFILE\.claude\plugins"
$tgStateDir = Join-Path $pluginRoot 'claude-plugins-official\telegram'
$tgPluginDir = $null
if (Test-Path $tgStateDir) {
    $tgPluginDir = $tgStateDir
} elseif (Test-Path $pluginRoot) {
    $found = Get-ChildItem -Path $pluginRoot -Recurse -Directory -Filter 'telegram' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $tgPluginDir = $found.FullName }
}

if ($tgPluginDir) {
    # Fix A: write the bot token into the plugin's state .env as LF-only.
    # WHY: the plugin's runtime is bun, and bun reads a trailing CRLF "\r" into
    # the token value, which then fails Telegram auth with a confusing 401.
    if ($botToken) {
        $tgEnv = Join-Path $tgPluginDir '.env'
        [IO.File]::WriteAllText($tgEnv, "TELEGRAM_BOT_TOKEN=$botToken`n")
    }
    # Fix B: point the plugin's MCP config at an absolute bun.exe path.
    # WHY: Windows PATH often can't resolve bare 'bun' for the spawned MCP
    # process, so the channel silently fails to start.
    $bunExe = "$env:USERPROFILE\.bun\bin\bun.exe"
    $mcpJson = Join-Path $tgPluginDir '.mcp.json'
    if ((Test-Path $mcpJson) -and (Test-Path $bunExe)) {
        $mcpRaw = Get-Content $mcpJson -Raw
        if ($mcpRaw -match '"command"\s*:\s*"bun"') {
            $escaped = $bunExe.Replace('\', '\\')
            $patched = $mcpRaw -replace '"command"\s*:\s*"bun"', "`"command`": `"$escaped`""
            [IO.File]::WriteAllText($mcpJson, $patched)
            Write-Host "Patched telegram plugin to use $bunExe" -ForegroundColor DarkGray
        }
    }
}

$botName = Get-DotEnvValue 'BOT_NAME'
if (-not $botName) { $botName = 'your bot' }
Write-Host ""
Write-Host "  $botName" -ForegroundColor Yellow -NoNewline
Write-Host " — v2 (journal/timeline/recall channels + tiered agents)" -ForegroundColor DarkGray
Write-Host ""

# --- resolve mode: fresh-restart marker > flags > interactive menu -----------
# WHY the marker: Claude Code `--continue` on an aged/over-limit session shows
# a BLOCKING "resume from summary" picker that stalls a headless loop, and no
# flag skips it. Detached auto-restarts drop this one-shot marker so the
# relaunch starts FRESH; the v2 journal/timeline/recall channels rebuild
# context at session-start, so it's ~lossless.
$freshMarker = Join-Path $repo '.claude\.bot_fresh_restart'
$forceFresh = $false
try {
    if (Test-Path $freshMarker) {
        $age = ((Get-Date) - (Get-Item $freshMarker).LastWriteTime).TotalSeconds
        Remove-Item $freshMarker -Force -ErrorAction SilentlyContinue  # one-shot
        if ($age -lt 300) { $forceFresh = $true }
    }
} catch {}

$resume = $null
if ($forceFresh) {
    $resume = $false
    Write-Host "  auto-restart marker -> FRESH session (journal/timeline/recall restore context)." -ForegroundColor Green
} elseif ($Continue) {
    $resume = $true
} elseif ($Fresh) {
    $resume = $false
} else {
    Write-Host "  [1] Continue last session (default — long-running)" -ForegroundColor Cyan
    Write-Host "  [2] Start fresh session" -ForegroundColor Green
    Write-Host ""
    $choice = Read-Host "  Choice (1/2, blank=1)"
    $resume = ($choice -ne '2')
}

# --- Telegram single-poller owner-lock ----------------------------------------
# The TG Bot API allows only ONE getUpdates long-poller per token. A second
# instance launching with --channels SIGTERM-steals the slot and the first
# poller 409s into a permanent dead state. So before launching we claim an
# exclusive owner-lock; if a LIVE foreign owner holds it, launch WITHOUT
# --channels.
$channels = $null
if ($botToken) { $channels = 'plugin:telegram@claude-plugins-official' }

$lockFile   = Join-Path $repo '.claude\.tg_owner.lock'
$botPidFile = "$env:USERPROFILE\.claude\channels\telegram\bot.pid"
$canOwn = $true
if ($channels -and (Test-Path $lockFile)) {
    $lockOwnerPid = 0
    try { $lockOwnerPid = Get-FirstPid ((Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1)) } catch {}
    $botPidAlive = $false
    if (Test-Path $botPidFile) {
        $bp = 0
        try { $bp = Get-FirstPid ((Get-Content $botPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)) } catch {}
        $botPidAlive = Test-BotPidAlive $bp
    }
    if ((Test-BotPidAlive $lockOwnerPid) -and $botPidAlive) {
        $canOwn = $false
        Write-Host "  Another instance owns the Telegram poller (PID $lockOwnerPid); launching WITHOUT --channels to avoid a 409 conflict." -ForegroundColor Yellow
    }
}

if ($channels -and $canOwn) {
    try {
        if (-not (Test-Path "$repo\.claude")) { New-Item -ItemType Directory -Force -Path "$repo\.claude" | Out-Null }
        # WriteAllText emits UTF-8 with NO BOM (Set-Content -Encoding utf8 on
        # PS 5.1 prepends a BOM that defeats the lock parse).
        [System.IO.File]::WriteAllText($lockFile, "$PID`n$((Get-Date).ToString('o'))")
    } catch {}
} elseif (-not $canOwn) {
    $channels = $null
}

# --- authoritative PID state record -------------------------------------------
# Single source of truth for the running instance's PIDs, written on EVERY
# launch. claude_pid is null now; the supervisor fills it once it resolves the
# foreground child. FAIL-OPEN.
try {
    $state = [ordered]@{
        claude_pid = $null
        shell_pid  = $PID
        session_id = $null
        started_at = (Get-Date).ToString('o')
        started_by = $StartedBy
        updated_at = (Get-Date).ToString('o')
        poller     = $(if ($channels) { 'OWNED' } else { 'NONE' })
        status     = 'starting'
    }
    [System.IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json))
} catch {}

# One-line launch trace.
try {
    $logDir = Join-Path $repo 'memory\metrics'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    Add-Content -Path (Join-Path $logDir 'launches.log') -Value "$((Get-Date).ToString('o'))  launch shell_pid=$PID started_by=$StartedBy resume=$resume" -Encoding utf8 -ErrorAction SilentlyContinue
} catch {}

# Tell child processes (statusline.js) whether THIS instance owns the TG
# poller, so only the owner shows the TG health indicator.
$env:BOT_HAS_TG = if ($channels) { '1' } else { '0' }

# --channels + the TG plugin enablement are included ONLY when we own the
# poller slot. Enablement rides in via --settings (tg-enable.settings.json)
# instead of .claude/settings.json / settings.local.json: a settings-file
# enablement is auto-loaded by EVERY claude launch in this repo cwd — plain
# `claude`, headless --print spawns — each starting a bridge that STEALS the
# poll slot. --channels alone does NOT load a disabled plugin, so enablement
# must live in a file we pass explicitly, and only when we own the poller.
$channelArgs = if ($channels) {
    @('--channels', $channels, '--settings', "$repo\.claude\tg-enable.settings.json")
} else { @() }

if (-not $resume) {
    Write-Host "  Starting fresh — journal will be created by the session-start hook." -ForegroundColor Green
    claude --dangerously-skip-permissions @channelArgs @Passthrough
} else {
    Write-Host "  Resuming — journal/timeline restore prior context." -ForegroundColor Cyan
    claude --dangerously-skip-permissions --continue @channelArgs @Passthrough
}
