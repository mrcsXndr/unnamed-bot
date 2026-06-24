# bot-supervisor.ps1 - ensure exactly ONE healthy bot session is always running.
#
# Run by a scheduled task on TWO triggers: At Logon (boot daemon) AND every few
# minutes (recurring liveness check). Each tick:
#   1. Single-instance: hold a global mutex so two ticks never act at once.
#   2. Resolve bot liveness from the owner-lock (the launcher pwsh PID) + the
#      Telegram poller probe (tg_watchdog.py --probe-only, the 409 trick).
#   3. Decide + act (bot PROCESS liveness is AUTHORITATIVE - a poller that still
#      answers 409 after the bot window was killed is an ORPHAN; never let it
#      mask a dead process):
#        no bot proc                         -> COLD-START (reboot / killed window).
#        bot proc alive + poller DEAD        -> RESTART (poller permanently 409'd).
#        bot proc alive + poller ALIVE/UNK   -> healthy / transient, do nothing.
#   4. Backoff: at most MaxStartsPerWindow (re)starts per WindowMin, to avoid a
#      crash-loop hammering launches.
#   5. Keep .bot_v2_state.json current with the live exact PIDs (claude + shell) so
#      every running bot is traceable and the launcher's duplicate-guard works.
#
# RESTART goes through scripts/restart-bot.ps1 (wait-for-old-PID-then-relaunch).
# COLD-START launches directly via Start-BotCold (the 'AssistantBot' WT profile ->
# mybot -Continue). NOTE: cold-start must NOT use restart-bot -OldPid 0 - PID 0 is
# the System Idle Process (reads "alive"), so it would wait+timeout.
#
# "Prevent multiple runners": the mutex serialises ticks; we NEVER launch when a
# healthy bot is already up; the launcher's own TG owner-lock stops a second
# poller. So the automated path cannot create duplicates.
#
# STRICTLY FAIL-OPEN: every failure is logged; the script always exits 0.
#
# Usage:
#   pwsh -NoProfile -File bot-supervisor.ps1            # act
#   pwsh -NoProfile -File bot-supervisor.ps1 -ProbeOnly # report state, no action
#   pwsh -NoProfile -File bot-supervisor.ps1 -DryRun    # decide + log, no launch

param(
    [switch]$ProbeOnly,
    [switch]$DryRun,
    [int]$MaxStartsPerWindow = 3,
    [int]$WindowMin = 30
)

$ErrorActionPreference = 'Continue'

# Repo root = parent of this scripts/ dir (no hardcoded user path).
$repo        = Split-Path -Parent $PSScriptRoot
$logDir      = Join-Path $repo 'memory\metrics'
$logFile     = Join-Path $logDir 'supervisor.log'
$lockFile    = Join-Path $repo '.claude\.tg_owner.lock'
$stateFile   = Join-Path $repo '.claude\.bot_v2_state.json'
$restartScript = Join-Path $repo 'scripts\restart-bot.ps1'
$watchdog    = Join-Path $repo 'tools\v2\tg_watchdog.py'

# Resolve a python interpreter from PATH (no hardcoded version dir). Override
# with BOT_PYTHON if your interpreter isn't on PATH.
function Resolve-PyExe {
    if ($env:BOT_PYTHON -and (Test-Path $env:BOT_PYTHON)) { return $env:BOT_PYTHON }
    foreach ($name in @('python.exe', 'python3.exe', 'python', 'python3')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return 'python'
}
$pyExe = Resolve-PyExe

function Write-SupLog {
    param([string]$Message)
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        "$((Get-Date).ToString('s'))  $Message" | Out-File -FilePath $logFile -Append -Encoding utf8
    } catch {}
    Write-Host $Message
}

function Get-FirstPid {
    param([string]$Raw)
    if ($Raw -and ($Raw -match '\d+')) { return [int]$matches[0] }
    return 0
}

# Read .bot_v2_state.json fail-open; $null on missing/corrupt/unreadable.
function Read-BotState {
    try {
        if (-not (Test-Path $stateFile)) { return $null }
        $raw = Get-Content $stateFile -Raw -ErrorAction SilentlyContinue
        if (-not $raw -or -not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

# Merge $Updates (hashtable) over the existing state (preserving started_at /
# started_by / session_id when already present) and write atomically with NO
# BOM, same shape as the launcher. FAIL-OPEN: any failure is logged, swallowed.
function Write-BotState {
    param([hashtable]$Updates)
    try {
        $cur = Read-BotState
        $merged = [ordered]@{
            claude_pid = $null
            shell_pid  = $null
            session_id = $null
            started_at = $null
            started_by = $null
            updated_at = $null
            poller     = $null
            status     = $null
        }
        if ($cur) {
            foreach ($k in @($merged.Keys)) {
                if ($cur.PSObject.Properties.Name -contains $k) { $merged[$k] = $cur.$k }
            }
        }
        foreach ($k in $Updates.Keys) { $merged[$k] = $Updates[$k] }
        if (-not (Test-Path (Split-Path $stateFile -Parent))) {
            New-Item -ItemType Directory -Force -Path (Split-Path $stateFile -Parent) | Out-Null
        }
        [System.IO.File]::WriteAllText($stateFile, ($merged | ConvertTo-Json))
    } catch {
        Write-SupLog "could not write .bot_v2_state.json (fail-open): $($_.Exception.Message)"
    }
}

function Test-ProcAlive {
    # Alive AND (optionally) one of the expected process names (guards PID reuse).
    param([int]$ProcId, [string[]]$Names)
    if ($ProcId -le 0) { return $false }
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($Names) { return ($Names -contains $p.ProcessName) }
    return $true
}

function Get-RecentStartCount {
    # Count "ACTION=START" markers logged within the rolling window.
    param([int]$WindowMinutes)
    $cutoff = (Get-Date).AddMinutes(-$WindowMinutes)
    $n = 0
    try {
        if (-not (Test-Path $logFile)) { return 0 }
        foreach ($line in Get-Content $logFile -ErrorAction SilentlyContinue) {
            if ($line -notmatch 'ACTION=START') { continue }
            $stampStr = ($line -split '\s\s', 2)[0]
            $ts = $null
            if ([datetime]::TryParse($stampStr, [ref]$ts)) {
                if ($ts -ge $cutoff) { $n++ }
            }
        }
    } catch {}
    return $n
}

function Resolve-PwshExe {
    $p = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $p) {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
        $p = if (Test-Path $alias) { $alias } else { 'powershell' }
    }
    return $p
}

function Start-BotViaRestart {
    # RESTART case only: spawn restart-bot.ps1 DETACHED with the live claude PID
    # (+ owner shell). It waits for that PID to exit (we kill it) then relaunches.
    # NOTE: do NOT use this for cold-start with OldPid 0 - Get-Process -Id 0 is
    # the System Idle Process (reports "alive"), so restart-bot would wait+timeout
    # instead of relaunching. Cold-start uses Start-BotCold (direct launch).
    param([Parameter(Mandatory)][int]$OldPid, [int]$OldShellPid = 0)
    $a = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
           '-File', $restartScript, '-OldPid', "$OldPid")
    if ($OldShellPid -gt 0) { $a += @('-OldShellPid', "$OldShellPid") }
    Start-Process -FilePath (Resolve-PwshExe) -ArgumentList $a -WindowStyle Hidden
}

function Start-BotCold {
    # COLD-START case: no old process to wait for, just launch. Prefer the
    # 'AssistantBot' WT profile (its commandline dot-sources the launcher + runs
    # mybot -Continue, closeOnExit:always); fall back to a plain pwsh window
    # doing the same. Returns a short description of how it launched.
    $launcher = Join-Path $repo 'scripts\launch.ps1'
    # Force FRESH on cold-start (same reason as restart-bot): CC `--continue` on an
    # aged session can show a BLOCKING resume-from-summary picker that stalls the
    # headless loop and no flag skips it. The launcher reads + deletes this
    # one-shot marker and starts fresh; journal/timeline/recall rebuild context.
    try {
        New-Item -ItemType File -Path (Join-Path $repo '.claude\.bot_fresh_restart') -Force | Out-Null
        Write-SupLog "dropped fresh-restart marker -> cold-start will be FRESH"
    } catch {}
    $wtCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
    $wtAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    $wtPath = if ($wtCmd) { $wtCmd.Source } elseif (Test-Path $wtAlias) { $wtAlias } else { $null }
    if ($wtPath) {
        Start-Process -FilePath $wtPath -ArgumentList @('-p', 'AssistantBot')
        return "wt -p AssistantBot"
    }
    $inner = "if (Test-Path `$PROFILE) { . `$PROFILE }; . '$launcher'; mybot -Continue"
    Start-Process -FilePath (Resolve-PwshExe) -ArgumentList @('-NoExit','-NoProfile','-Command', $inner)
    return "pwsh -NoExit (dot-source launcher + mybot -Continue)"
}

# --- single instance --------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\AssistantBotSupervisor')
$haveMutex = $false
try { $haveMutex = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }  # prior holder died; we own it
if (-not $haveMutex) {
    Write-SupLog 'another supervisor tick holds the mutex; exiting'
    exit 0
}

try {
    # --- resolve bot process liveness via the owner-lock --------------------
    $ownerPid = 0
    if (Test-Path $lockFile) {
        $ownerPid = Get-FirstPid ((Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1))
    }
    # The owner-lock holds the launcher SHELL pid (pwsh/powershell) that hosts
    # claude as a foreground child. Shell alive => bot session alive.
    $botAlive = Test-ProcAlive $ownerPid @('pwsh','powershell')
    $claudePid = 0
    if ($botAlive) {
        try {
            $kid = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ownerPid" -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -eq 'claude.exe' } | Select-Object -First 1
            if ($kid) { $claudePid = [int]$kid.ProcessId }
        } catch {}
    }

    # --- poller liveness via the tested 409 probe ---------------------------
    $poller = 'UNKNOWN'
    try {
        $out = (& $pyExe $watchdog --probe-only 2>$null | Select-Object -First 1)
        if ($out) { $poller = $out.Trim() }
    } catch {}
    if ($poller -notin @('ALIVE','DEAD','UNKNOWN')) { $poller = 'UNKNOWN' }

    Write-SupLog "state: ownerPid=$ownerPid botAlive=$botAlive claudePid=$claudePid poller=$poller"

    # --- keep .bot_v2_state.json current with the live exact PIDs ------------
    # When the bot is alive, write the authoritative record so the live PID trace
    # stays accurate even after a MANUAL launch (the launcher seeds it at
    # 'starting' with claude_pid=null; the supervisor fills claude_pid + flips
    # status to 'running'). started_at/started_by/session_id are preserved via
    # the merge. ProbeOnly is a PURE report -> no write.
    if ($botAlive -and -not $ProbeOnly) {
        Write-BotState @{
            claude_pid = $(if ($claudePid -gt 0) { $claudePid } else { $null })
            shell_pid  = $ownerPid
            updated_at = (Get-Date).ToString('o')
            poller     = $poller
            status     = 'running'
        }
    }

    if ($ProbeOnly) { Write-SupLog 'probe-only; no action'; exit 0 }

    # --- decide the action --------------------------------------------------
    # bot PROCESS liveness is AUTHORITATIVE. A poller answering 409 (ALIVE) while
    # the bot claude is DEAD is an ORPHANED plugin poller (the telegram MCP
    # subprocess can outlive a killed Terminal window): it holds the getUpdates
    # slot but no claude processes messages, so the bot is effectively down.
    # Therefore check the process FIRST - never let poller=ALIVE mask a dead bot.
    $action = 'none'
    if (-not $botAlive) {
        $action = 'cold-start'              # process gone -> (re)launch regardless of poller
    } elseif ($poller -eq 'DEAD') {
        $action = 'restart'                 # proc alive but poller permanently 409'd
    } else {
        $action = 'none'                    # proc alive + poller ALIVE/UNKNOWN -> healthy/transient
    }

    if ($action -eq 'none') { Write-SupLog "no action (botAlive=$botAlive poller=$poller)"; exit 0 }
    if ($DryRun) { Write-SupLog "DRYRUN would $action (botAlive=$botAlive poller=$poller)"; exit 0 }

    # Backoff before any (re)start.
    $recent = Get-RecentStartCount -WindowMinutes $WindowMin
    if ($recent -ge $MaxStartsPerWindow) {
        Write-SupLog "start cap hit ($recent/${WindowMin}m) - refusing to $action; manual launch needed"
        exit 0
    }

    if ($action -eq 'restart') {
        Write-SupLog "ACTION=START kind=restart (poller DEAD, bot proc alive)"
        # Tag who initiated the relaunch BEFORE launching (the WT-profile launch
        # path can't carry -StartedBy, so stamp the trace here). Fail-open.
        Write-BotState @{ started_by = 'supervisor-restart'; updated_at = (Get-Date).ToString('o'); status = 'restarting' }
        Start-BotViaRestart -OldPid $claudePid -OldShellPid $ownerPid
        # restart-bot waits for claudePid to exit; terminate it so it can relaunch.
        if ($claudePid -gt 0) {
            try { Stop-Process -Id $claudePid -Force -ErrorAction SilentlyContinue } catch {}
        } elseif ($ownerPid -gt 0) {
            try { Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue } catch {}
        }
    } else {  # cold-start
        # Kill any ORPHANED poller (a bun/node getUpdates process still holding the
        # slot though the bot is dead) so the fresh instance owns a clean slot.
        # Name-guard to avoid killing a reused PID.
        try {
            $bpFile = "$env:USERPROFILE\.claude\channels\telegram\bot.pid"
            if (Test-Path $bpFile) {
                $bp = Get-FirstPid ((Get-Content $bpFile -ErrorAction SilentlyContinue | Select-Object -First 1))
                if ($bp -gt 0) {
                    $bpProc = Get-Process -Id $bp -ErrorAction SilentlyContinue
                    if ($bpProc -and ($bpProc.ProcessName -in @('bun','node','node.exe','bun.exe'))) {
                        Write-SupLog "killing orphaned poller bot.pid=$bp ($($bpProc.ProcessName)) before cold-start"
                        Stop-Process -Id $bp -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {}
        Write-SupLog "ACTION=START kind=cold-start (bot process down)"
        # Tag the launch source BEFORE launching (WT-profile launch can't carry
        # -StartedBy). Fail-open. NOTE: the bot is down here, so we set claude_pid/
        # shell_pid null to avoid leaving a stale-but-live-looking record; the
        # fresh launcher reseeds shell_pid + the next tick fills claude_pid.
        Write-BotState @{ started_by = 'supervisor-cold'; claude_pid = $null; shell_pid = $null; updated_at = (Get-Date).ToString('o'); status = 'cold-starting' }
        $how = Start-BotCold
        Write-SupLog "cold-start launched via: $how"
    }
}
catch {
    Write-SupLog "EXCEPTION (fail-open): $($_.Exception.Message)"
}
finally {
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
}
exit 0
