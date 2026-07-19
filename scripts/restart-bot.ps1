# restart-bot.ps1 — wait for the old claude session to exit, then relaunch.
#
# Part of the self-restart flow (supervisor + /update). The running claude
# session cannot relaunch itself in-place: the launcher does `claude
# --continue`, which resumes the MOST-RECENT conversation. If a new instance
# starts while the old process is still alive, BOTH attach the same
# conversation -> state races + double Telegram replies.
#
# Contract: the caller spawns THIS script DETACHED, passing the live claude
# PID, then terminates that claude process. This script polls until the PID is
# gone, THEN launches a fresh window.
#
# Usage:
#   pwsh -NoProfile -File restart-bot.ps1 -OldPid 17808
#   pwsh -NoProfile -File restart-bot.ps1 -OldPid 17808 -DryRun
#
# Fully fail-open: every failure is logged, never throws. Worst case the
# operator relaunches manually (scripts\launch.ps1).

param(
    [Parameter(Mandatory = $true)]
    [int]$OldPid,

    # Launcher shell PID (powershell/pwsh) that owns the OLD window. When > 0
    # and alive, it is force-closed AFTER the old claude PID exits, so the old
    # window does not linger at a prompt.
    [int]$OldShellPid = 0,

    # Seconds to wait for the old PID to exit before giving up.
    [int]$TimeoutSec = 60,

    # Log the relaunch command instead of executing it (for testing).
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$repo    = Split-Path $PSScriptRoot -Parent
$logDir  = Join-Path $repo 'memory\metrics'
$logFile = Join-Path $logDir 'restart.log'

function Write-RestartLog {
    param([string]$Message)
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        "$((Get-Date).ToString('s'))  [pid=$OldPid] $Message" | Out-File -FilePath $logFile -Append -Encoding utf8
    } catch {}
}

function Get-DotEnvValue {
    param([string]$Key)
    $envFile = Join-Path $repo '.env'
    if (-not (Test-Path $envFile)) { return $null }
    foreach ($line in Get-Content $envFile -ErrorAction SilentlyContinue) {
        if ($line -match "^\s*$Key\s*=\s*(.+?)\s*$") {
            $val = $matches[1].Trim('"').Trim("'")
            if ($val) { return $val }
        }
    }
    return $null
}

Write-RestartLog "restart-bot invoked (timeout=${TimeoutSec}s, dryrun=$DryRun)"

# --- 1. Poll until the old claude PID is gone -------------------------------
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$exited = $false
while ((Get-Date) -lt $deadline) {
    $proc = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
    if (-not $proc) { $exited = $true; break }
    Start-Sleep -Milliseconds 500
}

if (-not $exited) {
    # Relaunching now would create the double-attach race we're guarding
    # against. Bail loud (in log) and let the operator sort it out.
    Write-RestartLog "TIMEOUT: pid $OldPid still alive after ${TimeoutSec}s. NOT relaunching (would race). Operator: relaunch manually once the old session exits."
    exit 1
}

Write-RestartLog "old session exited; preparing relaunch"

# --- 1b. Close the OLD launcher shell (the lingering window) ----------------
if ($OldShellPid -gt 0) {
    try {
        if ($DryRun) {
            Write-RestartLog "DRYRUN would close old shell PID $OldShellPid"
        } else {
            $shellProc = Get-Process -Id $OldShellPid -ErrorAction SilentlyContinue
            if ($shellProc) {
                Stop-Process -Id $OldShellPid -Force -ErrorAction Stop
                Write-RestartLog "closed old shell PID $OldShellPid"
            }
        }
    } catch {
        Write-RestartLog "could not close old shell PID ${OldShellPid}: $($_.Exception.Message)"
    }
}

# --- 2. Relaunch with --continue (long-running context is load-bearing) ------
# restart-bot is ONLY invoked to relaunch a session that was RECENTLY ALIVE (the
# supervisor's restart path kills a live claude; manual -OldPid targets a running
# PID). A just-killed session is NOT aged, so `--continue` resumes cleanly without
# the Claude Code "resume from summary" picker — that blocking picker only fires
# on genuinely aged sessions (the cold-start-after-reboot case, handled by the
# supervisor's cold-start path, which sets the fresh marker itself). Forcing FRESH
# here would THROW AWAY the just-killed session's working context. So we DELETE any
# stale fresh marker and let the relaunch --continue.
try {
    $freshMarker = Join-Path $repo '.claude\.bot_fresh_restart'
    if (Test-Path $freshMarker) { Remove-Item $freshMarker -Force -ErrorAction SilentlyContinue }
    Write-RestartLog "relaunch will --continue (no fresh marker; long-running context preserved)"
} catch {
    Write-RestartLog "marker cleanup note: $($_.Exception.Message)"
}

# --- 3. Launch in a fresh terminal -------------------------------------------
# If BOT_WT_PROFILE is set in .env (a Windows Terminal profile whose command
# line runs scripts\launch.ps1 -Continue, ideally with closeOnExit:always),
# prefer that. Otherwise open a plain pwsh window running the launcher.
$launcher = Join-Path $repo 'scripts\launch.ps1'

$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwshAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
$shellExe = 'powershell'
if ($pwshCmd) { $shellExe = $pwshCmd.Source }
elseif (Test-Path $pwshAlias) { $shellExe = $pwshAlias }

$wtProfile = Get-DotEnvValue 'BOT_WT_PROFILE'
$wtCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
$wtAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
$wtPath = $null
if ($wtCmd) { $wtPath = $wtCmd.Source } elseif (Test-Path $wtAlias) { $wtPath = $wtAlias }

$relaunchDesc = if ($wtProfile -and $wtPath) {
    "wt -w 0 -p '$wtProfile' (reuse MRU window)"
} else {
    "$shellExe -NoExit -File $launcher -Continue -StartedBy supervisor-restart"
}

if ($DryRun) {
    Write-RestartLog "DRYRUN would relaunch via -> $relaunchDesc"
    Write-Host "DRYRUN: would relaunch via $relaunchDesc"
    exit 0
}

try {
    if ($wtProfile -and $wtPath) {
        # `-w 0` = open the new tab in the MOST-RECENTLY-USED WT window instead
        # of spawning a new one (windowingBehavior defaults to useNew, which
        # left the old window on screen after every restart).
        Start-Process -FilePath $wtPath -ArgumentList @('-w', '0', '-p', $wtProfile)
    } else {
        Start-Process -FilePath $shellExe -ArgumentList @(
            '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $launcher, '-Continue', '-StartedBy', 'supervisor-restart'
        )
    }
    Write-RestartLog "relaunched OK via -> $relaunchDesc"
    exit 0
} catch {
    Write-RestartLog "RELAUNCH FAILED: $($_.Exception.Message). Operator: relaunch manually."
    exit 1
}
