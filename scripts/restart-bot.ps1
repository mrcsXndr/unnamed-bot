# restart-bot.ps1 - wait for the old Claude session to exit, then relaunch the bot.
#
# Part of the /update self-restart flow. The running Claude session cannot
# relaunch itself in-place: the launcher does `claude --continue`, which resumes
# the MOST-RECENT conversation. If a new session starts while the old process is
# still alive, BOTH attach the same conversation -> state races + double TG replies.
#
# So the contract is: update_restart.py spawns THIS script DETACHED, passing the
# live claude PID, then terminates that claude process. This script polls until
# the PID is gone, THEN launches a fresh bot window (which does --continue and
# safely resumes the now-single conversation).
#
# Usage:
#   powershell -NoProfile -File restart-bot.ps1 -OldPid 17808
#   powershell -NoProfile -File restart-bot.ps1 -OldPid 17808 -DryRun
#
# Fully fail-open: every failure is logged, never throws. Worst case the operator
# runs the bot launcher manually.

param(
    [Parameter(Mandatory = $true)]
    [int]$OldPid,

    # Launcher shell PID (powershell/pwsh) that owns the OLD window. When > 0 and
    # alive, it is force-closed AFTER the old claude PID exits, so the old window
    # does not linger at a prompt. NEVER a windowsterminal/wt PID - the caller
    # only resolves this when the parent is powershell.exe / pwsh.exe.
    [int]$OldShellPid = 0,

    # Seconds to wait for the old PID to exit before giving up.
    [int]$TimeoutSec = 60,

    # Log the relaunch command instead of executing it (for testing).
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

# Repo root = parent of this scripts/ dir (no hardcoded user path).
$repo    = Split-Path -Parent $PSScriptRoot
$logDir  = Join-Path $repo "memory\metrics"
$logFile = Join-Path $logDir "restart.log"

function Write-RestartLog {
    param([string]$Message)
    try {
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        }
        $stamp = (Get-Date).ToString('s')
        "$stamp  [pid=$OldPid] $Message" | Out-File -FilePath $logFile -Append -Encoding utf8
    } catch {
        # Logging itself failed - nothing more we can safely do.
    }
}

Write-RestartLog "restart-bot invoked (timeout=${TimeoutSec}s, dryrun=$DryRun)"

# --- 1. Poll until the old claude PID is gone -------------------------------
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$exited = $false
while ((Get-Date) -lt $deadline) {
    $proc = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
    if (-not $proc) {
        $exited = $true
        break
    }
    Start-Sleep -Milliseconds 500
}

if (-not $exited) {
    # Old process is still alive after the timeout. Relaunching now would create
    # the exact double-attach race we are guarding against. Bail loud (in log).
    Write-RestartLog "TIMEOUT: pid $OldPid still alive after ${TimeoutSec}s. NOT relaunching (would race). Operator: run the bot launcher manually once the old session exits."
    exit 1
}

Write-RestartLog "old session exited; preparing relaunch"

# --- 1b. Close the OLD launcher shell (the lingering window) ----------------
# Killing the old claude leaf leaves its parent powershell/pwsh shell at a
# prompt, so the old window lingers. Close it best-effort. Caller only passes a
# powershell/pwsh PID here (never windowsterminal/wt), so this is safe.
if ($OldShellPid -gt 0) {
    try {
        if ($DryRun) {
            Write-RestartLog "DRYRUN would close old shell PID $OldShellPid"
        } else {
            $shellProc = Get-Process -Id $OldShellPid -ErrorAction SilentlyContinue
            if ($shellProc) {
                Stop-Process -Id $OldShellPid -Force -ErrorAction Stop
                Write-RestartLog "closed old shell PID $OldShellPid"
            } else {
                Write-RestartLog "old shell PID $OldShellPid already gone; nothing to close"
            }
        }
    } catch {
        # Fail-open: a failure to close the old window must NOT block relaunch.
        Write-RestartLog "could not close old shell PID ${OldShellPid}: $($_.Exception.Message)"
    }
}

# --- 2. Resolve a robust bot invocation -------------------------------------
# The launcher (scripts/launch.ps1) defines an `Invoke-Bot` function aliased to
# `mybot`. A fresh window won't have the alias unless we re-establish it. Most
# robust: dot-source the launcher script directly, then call the function. We
# load $PROFILE first if present (for any user customisation), then dot-source
# the launcher as the source of truth.
$launcher = Join-Path $repo "scripts\launch.ps1"

# Inner command run in the new window. -NoExit keeps the window open so the
# session stays after launch. We invoke the bot with -Continue so the relaunch is
# fully hands-off (no Continue/Fresh keypress) - a self-restart must resume the
# now-single conversation, not block on an interactive menu.
$inner = @"
if (Test-Path `$PROFILE) { . `$PROFILE }
. '$launcher'
mybot -Continue
"@

# --- 3. Launch in a fresh terminal ------------------------------------------
# Prefer Windows Terminal (wt) for a clean new tab/window; fall back to a plain
# PowerShell window. wt is frequently a per-user App Execution Alias that does
# NOT resolve via Get-Command in a non-interactive child, so probe for the real
# exe too.
$wtCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
$wtAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wt.exe"
$wtPath = $null
if ($wtCmd) { $wtPath = $wtCmd.Source }
elseif (Test-Path $wtAlias) { $wtPath = $wtAlias }

# Prefer PowerShell 7 (pwsh) over Windows PowerShell 5.1 (better clipboard/paste).
# pwsh is often a per-user App Execution Alias that does NOT resolve via
# Get-Command in a non-interactive child, so probe the alias path too. Fall back
# to plain 'powershell' only if pwsh is unavailable.
$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwshAlias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\pwsh.exe"
$shellExe = 'powershell'
if ($pwshCmd) { $shellExe = $pwshCmd.Source }
elseif (Test-Path $pwshAlias) { $shellExe = $pwshAlias }

$relaunchDesc = if ($wtPath) {
    "wt -p 'AssistantBot' (profile cmd = dot-source launcher + mybot -Continue; closeOnExit:always)"
} else {
    "Start-Process $shellExe -NoExit -Command <dot-source launcher + mybot>"
}

if ($DryRun) {
    Write-RestartLog "DRYRUN would relaunch via -> $relaunchDesc"
    Write-RestartLog "DRYRUN inner command:`n$inner"
    Write-Host "DRYRUN: would relaunch via $relaunchDesc"
    exit 0
}

# --- 2b. Force the relaunch to start FRESH (one-shot marker) -----------------
# CC `--continue` on an aged/over-limit session can show a BLOCKING "resume from
# summary" picker that stalls a headless TG loop, and no flag skips it. A detached
# self-restart must be hands-off, so drop a marker the launcher reads + deletes on
# startup to force a FRESH session - the v2 journal/timeline/recall channels
# rebuild context at session-start (no real loss). This crosses the WT
# 'AssistantBot' profile boundary (which still passes -Continue; the marker wins).
try {
    $freshMarker = Join-Path $repo ".claude\.bot_fresh_restart"
    New-Item -ItemType File -Path $freshMarker -Force | Out-Null
    Write-RestartLog "dropped fresh-restart marker -> relaunch will start FRESH (journal/timeline restore)"
} catch {
    Write-RestartLog "could not drop fresh marker: $($_.Exception.Message) (relaunch may hit the resume prompt)"
}

try {
    if ($wtPath) {
        # Launch the dedicated 'AssistantBot' WT profile if the user defined one.
        # Its commandline should dot-source the launcher and run `mybot -Continue`,
        # with closeOnExit:always so the NEXT self-restart that kills this session
        # makes pwsh exit and WT auto-closes the tab (no lingering window). If no
        # such profile exists, WT opens its default profile - harmless; the user
        # can add the profile (see README). The OldShellPid kill above still
        # covers old non-profile windows during the transition.
        Start-Process -FilePath $wtPath -ArgumentList @('-p', 'AssistantBot')
    } else {
        # No Windows Terminal -> plain shell window. Keep -NoExit and rely on the
        # OldShellPid kill to close the previous window.
        Start-Process -FilePath $shellExe -ArgumentList @(
            '-NoExit', '-NoProfile', '-Command', $inner
        )
    }
    Write-RestartLog "relaunched OK via -> $relaunchDesc"
    exit 0
} catch {
    Write-RestartLog "RELAUNCH FAILED: $($_.Exception.Message). Operator: run the bot launcher manually."
    exit 1
}
