# launch.ps1 - one-command startup for the bot on Windows.
#
# Two ways to use it:
#   1. Direct:      powershell -ExecutionPolicy Bypass -File scripts\launch.ps1
#   2. Dot-source:  . scripts\launch.ps1   (then run `mybot` - wire this into
#                   $PROFILE so it's always available; see README).
#
# What it does:
#   1. Clones the repo from the public URL if it isn't there yet.
#   2. Optionally pulls your latest secrets/settings from a sync folder.
#   3. Makes the Telegram channel plugin work on Windows (two known gotchas).
#   4. Claims a single-poller owner-lock so two instances never dual-poll TG.
#   5. Resolves resume mode (Continue last / start Fresh) - interactive menu by
#      default, or non-interactive via -Continue / -Fresh (used by the detached
#      self-restart + supervisor cold-start paths).
#   6. Writes an authoritative PID state record (.claude/.bot_v2_state.json).
#   7. Launches Claude Code, attaching the Telegram channel plugin only when this
#      instance owns the poller slot.

# Repo root: prefer the location this script lives in (parent of scripts/), so a
# dot-sourced launcher works from anywhere. Fall back to a default clone path.
$script:BotRepoDefault = "C:\Users\$env:USERNAME\Code\my-bot"
$script:BotRepoUrl     = "https://github.com/YOUR_GH_USER/YOUR_REPO.git"

function Invoke-Bot {
    [CmdletBinding()]
    param(
        # Non-interactive resume controls (mutually exclusive). No flag => the
        # interactive Continue/Fresh menu. These let a detached/scripted relaunch
        # (restart-bot.ps1, bot-supervisor.ps1) launch hands-off with no keypress.
        [switch]$Continue,
        [switch]$Fresh,
        # Bypass the duplicate-launch guard (launch even if a live bot exists).
        [switch]$Force,
        # Trace tag for who initiated this launch (manual | supervisor-cold |
        # supervisor-restart). Recorded in .bot_v2_state.json + bot_launches.log.
        [string]$StartedBy = 'manual',
        # Any extra args are forwarded verbatim to claude.exe.
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Passthrough
    )

    $ErrorActionPreference = "Stop"

    if ($Continue -and $Fresh) {
        Write-Host "launch.ps1: -Continue and -Fresh are mutually exclusive." -ForegroundColor Red
        return
    }

    # --- 1. Repo location: prefer this script's repo, else clone the default ---
    $repo = $null
    if ($PSScriptRoot) {
        $candidate = Split-Path -Parent $PSScriptRoot
        if (Test-Path (Join-Path $candidate '.claude')) { $repo = $candidate }
    }
    if (-not $repo) {
        $repo = $script:BotRepoDefault
        if (-not (Test-Path $repo)) {
            Write-Host "Cloning bot into $repo ..." -ForegroundColor Cyan
            git clone $script:BotRepoUrl $repo
        }
    }
    Set-Location $repo

    # --- 2. Optional: pull settings from a sync folder ----------------------
    # If you keep secrets/settings in a cloud/USB folder, set BOT_SECRETS_DIR (or
    # SYNC_DRIVE_PATH) and this pulls the latest copy on the way in. It is a bash
    # script, so run it through Git Bash.
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    $syncScript = "$repo\tools\sync_settings.sh"
    $secretsDir = if ($env:BOT_SECRETS_DIR) { $env:BOT_SECRETS_DIR } else { $env:SYNC_DRIVE_PATH }
    if ($secretsDir -and (Test-Path $syncScript) -and (Test-Path $gitBash)) {
        Write-Host "Pulling latest settings from sync folder..." -ForegroundColor Cyan
        & $gitBash $syncScript pull 2>$null
    }

    # --- duplicate-launch guard ---------------------------------------------
    # One authoritative bot at a time. Liveness-based: a stale/dead PID in the
    # state never blocks (so the supervisor's cold-start/restart is never blocked).
    # FAIL-OPEN: any error reading state => proceed with launch.
    $stateFile = "$repo\.claude\.bot_v2_state.json"
    if (-not $Force) {
        $existing = $null
        try {
            if (Test-Path $stateFile) {
                $raw = Get-Content $stateFile -Raw -ErrorAction SilentlyContinue
                if ($raw -and $raw.Trim()) { $existing = $raw | ConvertFrom-Json -ErrorAction Stop }
            }
        } catch { $existing = $null }
        if ($existing) {
            $liveShell = $false; $liveClaude = $false
            try {
                if ($existing.shell_pid) {
                    $sp = Get-Process -Id ([int]$existing.shell_pid) -ErrorAction SilentlyContinue
                    if ($sp -and @('pwsh','powershell') -contains $sp.ProcessName) {
                        $kid = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($existing.shell_pid)" -ErrorAction SilentlyContinue |
                               Where-Object { $_.Name -eq 'claude.exe' } | Select-Object -First 1
                        $liveShell = [bool]$kid
                    }
                }
                if ($existing.claude_pid) {
                    $cp = Get-Process -Id ([int]$existing.claude_pid) -ErrorAction SilentlyContinue
                    $liveClaude = ($cp -and $cp.ProcessName -eq 'claude')
                }
            } catch {}
            if ($liveShell -or $liveClaude) {
                Write-Host ""
                Write-Host "  A bot session is already running - refusing to launch a duplicate." -ForegroundColor Yellow
                Write-Host "    claude_pid=$($existing.claude_pid)  shell_pid=$($existing.shell_pid)  started_at=$($existing.started_at)" -ForegroundColor Yellow
                Write-Host "    Use -Force to launch anyway." -ForegroundColor DarkGray
                Write-Host ""
                return
            }
        }
    }

    # --- 3. Telegram channel plugin: Windows fixes --------------------------
    # These make `--channels plugin:telegram@claude-plugins-official` actually
    # work on Windows. Both are no-ops if the plugin isn't installed or you don't
    # use Telegram, so the bot still launches fine without it.

    # Read TELEGRAM_BOT_TOKEN out of the repo .env (if present).
    $botToken = $null
    $envFile = "$repo\.env"
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$') {
                $val = $matches[1].Trim('"').Trim("'")
                # Ignore the placeholder shipped in .env.example.
                if ($val -and $val -notmatch 'YOUR_.*_HERE') { $botToken = $val }
            }
        }
    }

    # The telegram plugin keeps its own state dir under the Claude plugins cache.
    $pluginRoot = "$env:USERPROFILE\.claude\plugins"
    $tgStateDir = Join-Path $pluginRoot "claude-plugins-official\telegram"
    $tgPluginDir = $null
    if (Test-Path $tgStateDir) {
        $tgPluginDir = $tgStateDir
    } else {
        if (Test-Path $pluginRoot) {
            $found = Get-ChildItem -Path $pluginRoot -Recurse -Directory -Filter "telegram" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $tgPluginDir = $found.FullName }
        }
    }

    if ($tgPluginDir) {
        # Fix A: write the bot token into the plugin's state .env as LF-only.
        # WHY: the plugin's runtime is bun, and bun reads a trailing CRLF "\r"
        # into the token value, which then fails Telegram auth with a confusing
        # 401. Use [IO.File]::WriteAllText to force "\n" line endings.
        if ($botToken) {
            $tgEnv = Join-Path $tgPluginDir ".env"
            [IO.File]::WriteAllText($tgEnv, "TELEGRAM_BOT_TOKEN=$botToken`n")
        }

        # Fix B: point the plugin's MCP config at an absolute bun.exe path.
        # WHY: the plugin's .mcp.json runs "command":"bun", but Windows PATH often
        # can't resolve a bare 'bun' for the spawned MCP process, so the channel
        # silently fails to start. Rewrite it to the absolute bun.exe once.
        $bunExe = "$env:USERPROFILE\.bun\bin\bun.exe"
        $mcpJson = Join-Path $tgPluginDir ".mcp.json"
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

    # --- 4. Resolve resume mode ---------------------------------------------
    # A one-shot auto-restart MARKER forces FRESH (overrides everything incl
    # -Continue); else an explicit flag (non-interactive) wins; else prompt.
    #
    # WHY the marker: CC `--continue` on an aged/over-limit session can show a
    # BLOCKING "resume from summary" picker that stalls the headless TG loop, and
    # no flag/env/setting skips it interactively. Detached auto-restarts
    # (restart-bot.ps1 + bot-supervisor.ps1 cold-start) drop this marker right
    # before launch so the relaunch starts FRESH - the v2 journal/timeline/recall
    # channels rebuild context at session-start, so it's ~lossless. The launcher
    # reads + deletes it (one-shot).
    $freshMarker = "$repo\.claude\.bot_fresh_restart"
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
        Write-Host "  -Continue: resuming last session (non-interactive)." -ForegroundColor Cyan
    } elseif ($Fresh) {
        $resume = $false
        Write-Host "  -Fresh: starting fresh session (non-interactive)." -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  [1] Continue last session (default)" -ForegroundColor Cyan
        Write-Host "  [2] Start fresh session" -ForegroundColor Green
        Write-Host ""
        $choice = Read-Host "  Choice (1/2, blank=1)"
        $resume = ($choice -ne "2")
    }

    $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"
    if (-not (Test-Path $claudeExe)) { $claudeExe = "claude" }  # fall back to PATH
    $channels  = "plugin:telegram@claude-plugins-official"

    # --- 5. Telegram single-poller owner-lock -------------------------------
    # The TG Bot API allows only ONE getUpdates long-poller per token. A second
    # instance launching with --channels SIGTERM-steals the slot and the first
    # poller 409s into a permanent dead state. So before launching we claim an
    # exclusive owner-lock; if a LIVE foreign owner holds it, we launch WITHOUT
    # --channels.
    $lockFile = "$repo\.claude\.tg_owner.lock"
    $botPidFile = "$env:USERPROFILE\.claude\channels\telegram\bot.pid"

    function Test-PidAlive {
        param([int]$ProcId)
        if ($ProcId -le 0) { return $false }
        return [bool](Get-Process -Id $ProcId -ErrorAction SilentlyContinue)
    }
    # Extract the first digit-run from a possibly BOM/whitespace-prefixed string.
    # A UTF-8 BOM (U+FEFF) is a format char .Trim() does NOT strip, so [int]::Parse
    # on a BOM'd line fails. Regex side-steps the BOM. No digits -> 0.
    function Get-FirstPid {
        param([string]$Raw)
        if ($Raw -and ($Raw -match '\d+')) { return [int]$matches[0] }
        return 0
    }

    $canOwn = $true
    if (Test-Path $lockFile) {
        $lockOwnerPid = 0
        try { $lockOwnerPid = Get-FirstPid ((Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1)) } catch {}
        $botPidAlive = $false
        if (Test-Path $botPidFile) {
            $bp = 0
            try { $bp = Get-FirstPid ((Get-Content $botPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)) } catch {}
            $botPidAlive = Test-PidAlive $bp
        }
        if ((Test-PidAlive $lockOwnerPid) -and $botPidAlive) {
            $canOwn = $false
            Write-Host "  Another bot instance owns the Telegram poller (PID $lockOwnerPid); launching WITHOUT --channels to avoid a 409 conflict." -ForegroundColor Yellow
        } else {
            Write-Host "  Reclaiming stale Telegram owner-lock (owner PID $lockOwnerPid / bot.pid dead)." -ForegroundColor DarkGray
        }
    }

    if ($canOwn) {
        try {
            if (-not (Test-Path "$repo\.claude")) { New-Item -ItemType Directory -Force -Path "$repo\.claude" | Out-Null }
            # WriteAllText emits UTF-8 with NO BOM on both PS 5.1 and 7. A BOM here
            # only breaks the reader. Keep the PID\ntimestamp content shape.
            [System.IO.File]::WriteAllText($lockFile, "$PID`n$((Get-Date).ToString('o'))")
        } catch {
            Write-Host "  Could not write Telegram owner-lock (non-fatal); launching with --channels anyway." -ForegroundColor DarkGray
        }
    } else {
        $channels = $null
    }

    # --- 6. Authoritative PID state record ----------------------------------
    # Single source of truth for the running bot's exact PIDs. shell_pid is THIS
    # launcher shell; claude_pid/session_id are null now - the supervisor fills
    # claude_pid once it resolves the foreground child. NO BOM. FAIL-OPEN.
    try {
        $state = [ordered]@{
            claude_pid = $null
            shell_pid  = $PID
            session_id = $null
            started_at = (Get-Date).ToString('o')
            started_by = $StartedBy
            updated_at = (Get-Date).ToString('o')
            poller     = $(if ($canOwn) { 'OWNED' } else { 'FOREIGN' })
            status     = 'starting'
        }
        if (-not (Test-Path "$repo\.claude")) { New-Item -ItemType Directory -Force -Path "$repo\.claude" | Out-Null }
        [System.IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json))
    } catch {
        Write-Host "  Could not write bot state record (non-fatal)." -ForegroundColor DarkGray
    }

    # One-line launch trace.
    try {
        $logDir = "$repo\memory\metrics"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        "$((Get-Date).ToString('o'))  launch shell_pid=$PID started_by=$StartedBy resume=$resume" |
            Add-Content -Path "$logDir\bot_launches.log" -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}

    # Tell child processes (statusline.js) whether THIS instance owns the TG
    # poller, so ONLY the owner shows the TG indicator. '1' = owns --channels,
    # '0' = a foreign owner held the slot so we launched without it.
    $env:BOT_V2_HAS_TG = if ($canOwn) { '1' } else { '0' }

    # --channels is included ONLY when we own the poller slot.
    $channelArgs = if ($channels) { @('--channels', $channels) } else { @() }

    # --- 7. Launch ----------------------------------------------------------
    if (-not $resume) {
        Write-Host "  Starting fresh - journal will be created on the session-start hook." -ForegroundColor Green
        & $claudeExe --dangerously-skip-permissions @channelArgs $Passthrough
    } else {
        Write-Host "  Resuming - journal/timeline restore prior context." -ForegroundColor Cyan
        & $claudeExe --dangerously-skip-permissions --continue @channelArgs $Passthrough
    }
}

Set-Alias -Name mybot -Value Invoke-Bot -Scope Global -ErrorAction SilentlyContinue

# When run directly (powershell -File launch.ps1), invoke immediately and forward
# any args. When dot-sourced, this is skipped so the caller gets `mybot` defined.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Bot @args
}
