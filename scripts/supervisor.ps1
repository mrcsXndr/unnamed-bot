# supervisor.ps1 — ensure exactly ONE healthy bot instance is always running.
#
# Windows-only. OPT-IN: registered as a scheduled task by
# scripts\register-supervisor.ps1 (the setup wizard offers this). Runs on TWO
# triggers: At Logon (boot daemon) AND every few minutes (liveness check).
#
# Each tick:
#   1. Single-instance: hold a global mutex so two ticks never act at once.
#   2. Resolve bot liveness from the owner-lock (launcher shell PID) + the
#      Telegram poller probe (tg_watchdog.py --probe-only, the 409 trick).
#   3. Decide + act (bot PROCESS liveness is AUTHORITATIVE — a poller that
#      still answers 409 after the bot window was killed is an ORPHAN):
#        no bot proc                        -> COLD-START (reboot / killed window)
#        bot proc alive + poller DEAD       -> RESTART (poller permanently 409'd)
#        bot proc alive + poller ALIVE/UNK  -> healthy / transient, do nothing
#   4. Backoff: at most MaxStartsPerWindow (re)starts per WindowMin (no
#      crash-loop hammering).
#   5. Keep .claude/.bot_state.json current with the live PIDs.
#   6. Heartbeat (notify-only): commitments.py heartbeat TG-alerts due/overdue
#      commitments (cooldown-deduped). ISOLATED try/catch — never gates the
#      liveness decision.
#   7. Optional monitors (FEATURE_MONITORS=1): hourly-gated resource janitor.
#
# RESTART goes through scripts/restart-bot.ps1 (wait-for-old-PID-then-relaunch).
# COLD-START launches directly (NOT via restart-bot -OldPid 0 — PID 0 is the
# System Idle Process, which reads "alive", so restart-bot would wait+timeout).
#
# STRICTLY FAIL-OPEN: every failure is logged; the script always exits 0.
#
# Usage:
#   pwsh -NoProfile -File supervisor.ps1            # act
#   pwsh -NoProfile -File supervisor.ps1 -ProbeOnly # report state, no action
#   pwsh -NoProfile -File supervisor.ps1 -DryRun    # decide + log, no launch

param(
    [switch]$ProbeOnly,
    [switch]$DryRun,
    [int]$MaxStartsPerWindow = 3,
    [int]$WindowMin = 30
)

$ErrorActionPreference = 'Continue'

$repo          = Split-Path $PSScriptRoot -Parent
$logDir        = Join-Path $repo 'memory\metrics'
$logFile       = Join-Path $logDir 'supervisor.log'
$lockFile      = Join-Path $repo '.claude\.tg_owner.lock'
$stateFile     = Join-Path $repo '.claude\.bot_state.json'
$restartScript = Join-Path $repo 'scripts\restart-bot.ps1'
$launcher      = Join-Path $repo 'scripts\launch.ps1'
$watchdog      = Join-Path $repo 'tools\v2\tg_watchdog.py'

# Resolve python from PATH (fail-open to bare 'python').
$pyExe = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pyExe) { $pyExe = 'python' }

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

function Read-BotState {
    try {
        if (-not (Test-Path $stateFile)) { return $null }
        $raw = Get-Content $stateFile -Raw -ErrorAction SilentlyContinue
        if (-not $raw -or -not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

# Merge $Updates over the existing state and write atomically with NO BOM.
function Write-BotState {
    param([hashtable]$Updates)
    try {
        $cur = Read-BotState
        $merged = [ordered]@{
            claude_pid = $null; shell_pid = $null; session_id = $null
            started_at = $null; started_by = $null; updated_at = $null
            poller = $null; status = $null
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
        Write-SupLog "could not write .bot_state.json (fail-open): $($_.Exception.Message)"
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
    # RESTART case only: spawn restart-bot.ps1 DETACHED with the live claude
    # PID (+ owner shell). It waits for that PID to exit (we kill it) then
    # relaunches. NOT for cold-start with OldPid 0 (System Idle Process).
    param([Parameter(Mandatory)][int]$OldPid, [int]$OldShellPid = 0)
    $a = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
           '-File', $restartScript, '-OldPid', "$OldPid")
    if ($OldShellPid -gt 0) { $a += @('-OldShellPid', "$OldShellPid") }
    Start-Process -FilePath (Resolve-PwshExe) -ArgumentList $a -WindowStyle Hidden
}

function Start-BotCold {
    # COLD-START case: no old process to wait for, just launch. Prefer the
    # user's Windows Terminal profile if BOT_WT_PROFILE is set in .env; else a
    # plain pwsh window running the launcher. Returns a short description.
    #
    # Force FRESH on cold-start: `--continue` on an aged session shows a
    # BLOCKING resume-from-summary picker that stalls the headless loop. The
    # launcher reads + deletes this one-shot marker and starts fresh; the
    # journal/timeline/recall channels rebuild context.
    try {
        New-Item -ItemType File -Path (Join-Path $repo '.claude\.bot_fresh_restart') -Force | Out-Null
        Write-SupLog "dropped fresh-restart marker -> cold-start will be FRESH"
    } catch {}
    $wtProfile = Get-DotEnvValue 'BOT_WT_PROFILE'
    if ($wtProfile) {
        $wtCmd = Get-Command wt.exe -ErrorAction SilentlyContinue
        $wtAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
        $wtPath = if ($wtCmd) { $wtCmd.Source } elseif (Test-Path $wtAlias) { $wtAlias } else { $null }
        if ($wtPath) {
            Start-Process -FilePath $wtPath -ArgumentList @('-p', $wtProfile)
            return "wt -p $wtProfile"
        }
    }
    Start-Process -FilePath (Resolve-PwshExe) -ArgumentList @(
        '-NoExit','-NoProfile','-ExecutionPolicy','Bypass',
        '-File', $launcher, '-Continue', '-StartedBy', 'supervisor-cold'
    )
    return "pwsh -NoExit -File launch.ps1 -Continue"
}

function Invoke-CommitmentsHeartbeat {
    # Heartbeat (notify-only): surface DUE/overdue commitments to Telegram via
    # commitments.py heartbeat (cooldown-deduped per item). Fully ISOLATED:
    # every error is logged + swallowed so a commitments failure can NEVER
    # affect the liveness decision or crash the tick.
    param([switch]$AsDryRun)
    try {
        $hbScript = Join-Path $repo 'tools\v2\commitments.py'
        if (-not (Test-Path $hbScript)) { return }
        $hbArgs = @($hbScript, 'heartbeat')
        if ($AsDryRun) { $hbArgs += '--dry-run' }
        $env:PYTHONIOENCODING = 'utf-8'
        $out = & $pyExe @hbArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-SupLog "heartbeat: commitments exit=$LASTEXITCODE $((@($out) | Select-Object -First 2) -join ' | ')"
        } elseif ($out) {
            Write-SupLog "heartbeat: $((@($out) | Select-Object -Last 1))"
        }
    } catch {
        Write-SupLog "heartbeat: swallowed exception (fail-open): $($_.Exception.Message)"
    }
}

function Invoke-MonitorTick {
    # Optional app-health monitors folded into the supervisor (the only
    # restart/reboot-durable scheduler). OPT-IN via FEATURE_MONITORS=1 in .env.
    # Hourly-gated via .claude/.monitor_ticks.json so a 3-min tick only fires
    # them ~hourly. Runs ONLY on the healthy path, so monitor latency can't
    # delay a bot restart. Fully ISOLATED + fail-open.
    param([switch]$AsDryRun)
    try {
        if ((Get-DotEnvValue 'FEATURE_MONITORS') -ne '1') { return }
        $tickStateF = Join-Path $repo '.claude\.monitor_ticks.json'
        $now = Get-Date
        $st = @{}
        if (Test-Path $tickStateF) {
            try { (Get-Content $tickStateF -Raw | ConvertFrom-Json).PSObject.Properties |
                    ForEach-Object { $st[$_.Name] = $_.Value } } catch {}
        }
        $dueMin = 55   # ~hourly (3-min ticks reliably catch the 55-min mark)
        $isDue = {
            param($key)
            if (-not $st.ContainsKey($key) -or -not $st[$key]) { return $true }
            try { return ((($now - [datetime]$st[$key])).TotalMinutes -ge $dueMin) } catch { return $true }
        }
        $changed = $false
        # Box resource janitor + self-alert (-Clean kills stray automation
        # browsers; -Tg alerts on warn/critical).
        if (& $isDue 'resource') {
            if ($AsDryRun) { Write-SupLog 'monitor: DRYRUN would run resource' }
            else {
                & (Resolve-PwshExe) -NoProfile -File (Join-Path $repo 'tools\infra\resource_monitor.ps1') -Clean -Tg 2>&1 | Out-Null
                Write-SupLog "monitor: resource ran (exit=$LASTEXITCODE)"
                $st['resource'] = $now.ToString('o'); $changed = $true
            }
        }
        # Add your own monitors here following the same pattern: hourly-gated,
        # self-alerting, read-only, fail-open.
        if ($changed) {
            try { ($st | ConvertTo-Json) | Out-File -FilePath $tickStateF -Encoding utf8 } catch {}
        }
    } catch {
        Write-SupLog "monitor: swallowed exception (fail-open): $($_.Exception.Message)"
    }
}

# --- single instance --------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeBotSupervisor')
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

    # --- poller liveness via the 409 probe -----------------------------------
    $poller = 'UNKNOWN'
    try {
        $env:PYTHONIOENCODING = 'utf-8'
        $out = (& $pyExe $watchdog --probe-only 2>$null | Select-Object -First 1)
        if ($out) { $poller = $out.Trim() }
    } catch {}
    if ($poller -notin @('ALIVE','DEAD','UNKNOWN')) { $poller = 'UNKNOWN' }

    Write-SupLog "state: ownerPid=$ownerPid botAlive=$botAlive claudePid=$claudePid poller=$poller"

    # --- keep .bot_state.json current with the live PIDs ---------------------
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

    # --- decide the action ----------------------------------------------------
    # Bot PROCESS liveness is AUTHORITATIVE. A poller answering 409 (ALIVE)
    # while claude is DEAD is an ORPHANED plugin poller (the telegram MCP
    # subprocess can outlive a killed terminal window): it holds the getUpdates
    # slot but no claude processes messages. Check the process FIRST.
    $action = 'none'
    if (-not $botAlive) {
        $action = 'cold-start'
    } elseif ($poller -eq 'DEAD') {
        $action = 'restart'
    }

    # --- heartbeat: due-commitments surfacing (isolated) ----------------------
    Invoke-CommitmentsHeartbeat -AsDryRun:$DryRun

    if ($action -eq 'none') {
        # Healthy: run the hourly-gated monitors here (never on the restart/
        # cold-start paths, so monitor latency can't delay recovery).
        Invoke-MonitorTick -AsDryRun:$DryRun
        Write-SupLog "no action (botAlive=$botAlive poller=$poller)"; exit 0
    }
    if ($DryRun) { Write-SupLog "DRYRUN would $action (botAlive=$botAlive poller=$poller)"; exit 0 }

    # Backoff before any (re)start.
    $recent = Get-RecentStartCount -WindowMinutes $WindowMin
    if ($recent -ge $MaxStartsPerWindow) {
        Write-SupLog "start cap hit ($recent/${WindowMin}m) - refusing to $action; manual launch needed"
        exit 0
    }

    if ($action -eq 'restart') {
        Write-SupLog "ACTION=START kind=restart (poller DEAD, bot proc alive)"
        Write-BotState @{ started_by = 'supervisor-restart'; updated_at = (Get-Date).ToString('o'); status = 'restarting' }
        Start-BotViaRestart -OldPid $claudePid -OldShellPid $ownerPid
        # restart-bot waits for claudePid to exit; terminate it so it can relaunch.
        if ($claudePid -gt 0) {
            try { Stop-Process -Id $claudePid -Force -ErrorAction SilentlyContinue } catch {}
        } elseif ($ownerPid -gt 0) {
            try { Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue } catch {}
        }
    } else {  # cold-start
        # Kill any ORPHANED poller (a bun/node getUpdates process still holding
        # the slot though the bot is dead) so the fresh instance owns a clean
        # slot. Name-guarded to avoid killing a reused PID.
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
