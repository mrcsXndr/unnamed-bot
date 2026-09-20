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
#      crash-loop hammering). Cold-start cap-check reads the START log with a
#      typed TryParse init — an untyped `$null` ref fails to bind on newer
#      PowerShell and silently returns 0 forever, defeating the cap.
#   4b. Cold-start hygiene: a launched-but-not-yet-alive launcher (tracked via
#      launcher_pid/launcher_started_at) blocks a second spawn while it's still
#      within LauncherGraceMin, and gets its process tree killed once it's
#      past that grace with no bot showing up (hung launcher).
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
    [int]$WindowMin = 30,
    # A cold-start launcher younger than this is "in progress" (no second
    # spawn); older and still without claude => hung -> killed.
    [int]$LauncherGraceMin = 4
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
            # Cold-start launcher tracking: lets the next tick tell "still
            # starting" from "hung" instead of spawning another.
            launcher_pid = $null; launcher_started_at = $null
            # Last alerts.log triage scan (Invoke-AlertTriage rate limit).
            triage_last_scan = $null
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
            # Typed init is load-bearing: with `$ts = $null` PowerShell 7.6
            # cannot bind the [ref] overload ("Cannot find an overload for
            # TryParse and the argument count: 2"), the catch below swallows
            # it, and this silently returns 0 forever — the start cap never
            # fires no matter how many times the loop spins.
            $ts = [datetime]::MinValue
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
    # A WT-profile launch has no single child pid to poll (wt hands off to a
    # separate process and its own launcher shell exits immediately), so only
    # the plain-pwsh path can be tracked. That's fine: WT profiles are opened
    # by the operator in the interactive session, where a hang is visible on
    # screen; the tracked path matters for the case a hang would otherwise be
    # silent (nobody watching the window).
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
    $p = Start-Process -FilePath (Resolve-PwshExe) -PassThru -ArgumentList @(
        '-NoExit','-NoProfile','-ExecutionPolicy','Bypass',
        '-File', $launcher, '-Continue', '-StartedBy', 'supervisor-cold'
    )
    Write-BotState @{ launcher_pid = $p.Id; launcher_started_at = (Get-Date).ToString('o') }
    return "pwsh -NoExit -File launch.ps1 -Continue (launcher pid $($p.Id))"
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

function Invoke-SessionExpiryMonitor {
    # Notify-only: warn AHEAD of a Claude login-session (refresh-token) expiry so
    # the bot never silently goes dark waiting on a manual /login. Reads
    # ~/.claude/.credentials.json -> claudeAiOauth.refreshTokenExpiresAt and
    # TG-alerts once per escalating tier (yellow <=3d, orange <=24h, red expired);
    # self-deduped inside the script (escalate-only, resets on re-login). Fully
    # ISOLATED + fail-open: never gates liveness or crashes the tick.
    param([switch]$AsDryRun)
    try {
        $seScript = Join-Path $repo 'tools\v2\session_expiry_monitor.py'
        if (-not (Test-Path $seScript)) { return }
        $seArgs = @($seScript)
        if ($AsDryRun) { $seArgs += '--dry-run' }
        $env:PYTHONIOENCODING = 'utf-8'
        $out = & $pyExe @seArgs 2>&1
        if ($out) { Write-SupLog "session_expiry: $((@($out) | Select-Object -Last 1))" }
    } catch {
        Write-SupLog "session_expiry: swallowed exception (fail-open): $($_.Exception.Message)"
    }
}

function Invoke-UsageProbe {
    # Live subscription-quota probe: refresh memory/metrics/usage_state.json (which
    # the statusline reads) and TG-warn on a threshold crossing. PROACTIVE, unlike
    # transcript-banner detection, which only fires once the session is already dark.
    #
    # Costs one ~9-token Haiku call, and usage_probe.py throttles itself to at most
    # one call per 5 min, so a 3-min tick cannot turn the quota check into its own
    # traffic. The statusline reads the cache only, never the network.
    # Fully ISOLATED + fail-open: never gates liveness.
    param([switch]$AsDryRun)
    try {
        $upScript = Join-Path $repo 'tools\v2\usage_probe.py'
        if (-not (Test-Path $upScript)) { return }
        $upArgs = @($upScript, 'probe')
        # --warn sends the TG threshold alert; skip it on a dry run so a diagnostic
        # pass can never message the operator.
        if (-not $AsDryRun) { $upArgs += '--warn' }
        $env:PYTHONIOENCODING = 'utf-8'
        $out = & $pyExe @upArgs 2>&1
        if ($out) { Write-SupLog "usage_probe: $((@($out) | Select-Object -Last 1))" }
    } catch {
        Write-SupLog "usage_probe: swallowed exception (fail-open): $($_.Exception.Message)"
    }
}

function Invoke-Bounded {
    # Run an external step with a HARD timeout, killing the whole process tree
    # if it overruns. Every step runs inside the single-instance mutex, so a
    # step invoked with a bare `& $exe ...` that blocks forever would disable
    # ALL liveness supervision — the opposite of the point. Set timeouts from
    # measured run times, not intuition: a cap below a healthy run's duration
    # silently ends that monitor. Returns the exit code, or $null if killed.
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 180,
        [string]$Label = 'step'
    )
    # ProcessStartInfo.ArgumentList, NOT Start-Process -ArgumentList: the latter
    # joins the array with spaces and does no quoting, so any argument containing
    # a space silently becomes two arguments. ArgumentList quotes each element.
    $p = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $Exe
        foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add([string]$a) }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # Output is discarded rather than buffered: redirecting without draining
        # the pipe would deadlock a chatty child on a full buffer.
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill($true) } catch { }   # $true = kill the child tree too
            Write-SupLog "$Label`: KILLED after ${TimeoutSec}s (was holding the tick)"
            return $null
        }
        return $p.ExitCode
    } catch {
        Write-SupLog "$Label`: launch failed (fail-open): $($_.Exception.Message)"
        return $null
    } finally {
        if ($p) { $p.Dispose() }
    }
}

function Invoke-AlertTriage {
    # The autonomous tick that READS memory/metrics/alerts.log. Monitors write
    # there (tg_send.py --alert) instead of pushing to the operator's phone, and
    # a log nobody reads is worse than a push. alert_triage.py scan classifies
    # the new lines, fingerprints the actionable ones (24h cooldown per
    # fingerprint) and, when there is a batch, spawns ONE detached headless
    # claude run that fixes what is confined to this box / a repo we own, cards
    # the rest on the task board, and answers NO_REPLY.
    #
    # Gates, in order: at most every BOT_TRIAGE_EVERY_MIN (30) via a stamp in
    # the state file; idle-gated by Test-SessionBusy (the run commits in repos
    # the live session may be editing — one writer per tree), WAIVED by the
    # script once the oldest alert has waited BOT_TRIAGE_MAX_WAIT_H (6) — the
    # run is then told not to commit in this repo beyond memory/metrics/; then
    # the script's own lock / BOT_TRIAGE_MAX_PER_DAY (6). The scan itself is bounded
    # here (120s); the LLM run is NOT held under this mutex — the detached
    # waiter (`alert_triage.py run`) owns the BOT_TRIAGE_TIMEOUT_MIN (25) hard
    # timeout and tree-kills an overrun, logging it to
    # memory/metrics/alerts_triage.log. Holding the tick for 25 minutes would
    # suspend liveness supervision. Fully ISOLATED + fail-open.
    param([switch]$AsDryRun)
    try {
        $script = Join-Path $repo 'tools\v2\alert_triage.py'
        if (-not (Test-Path $script)) { return }
        $every = 30; try { if ($env:BOT_TRIAGE_EVERY_MIN) { $every = [double]$env:BOT_TRIAGE_EVERY_MIN } } catch {}
        $st = Read-BotState
        if ($st -and ($st.PSObject.Properties.Name -contains 'triage_last_scan') -and $st.triage_last_scan) {
            $last = [datetime]::MinValue
            if ([datetime]::TryParse("$($st.triage_last_scan)", [ref]$last)) {
                if (((Get-Date) - $last).TotalMinutes -lt $every) { return }
            }
        }
        # The idle gate lives in the script: it knows the alerts' ages and waives
        # the gate once the oldest has waited BOT_TRIAGE_MAX_WAIT_H (6), because a
        # session busy for days would otherwise starve every alert.
        if (-not $AsDryRun) { Write-BotState @{ triage_last_scan = (Get-Date).ToString('o') } }
        $a = @($script, 'scan')
        if (Test-SessionBusy) { $a += '--session-busy' }
        if ($AsDryRun) { $a += '--dry-run' }
        $env:PYTHONIOENCODING = 'utf-8'
        $rc = Invoke-Bounded -Exe $pyExe -Arguments $a -TimeoutSec 120 -Label 'alert_triage'
        Write-SupLog "alert_triage: scan rc=$(if ($null -eq $rc) { 'killed' } else { $rc })$(if ($AsDryRun) { ' (dry-run)' })"
    } catch {
        Write-SupLog "alert_triage: swallowed exception (fail-open): $($_.Exception.Message)"
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

function Test-SessionBusy {
    # Is the live session ACTIVELY working? Signal = newest Claude Code TRANSCRIPT
    # (.jsonl) mtime. CC writes the transcript on every message + tool call, so it
    # tracks real activity continuously — unlike the journal, which the Director
    # only writes sporadically (a stale journal on a mid-conversation session would
    # FAIL to protect it). If ANY transcript was touched within $QuietMin minutes,
    # the session is mid-work -> BUSY. MUST BE RECURSIVE: background subagents and
    # workflows write to <session>/subagents/**/agent-*.jsonl while the MAIN
    # transcript sits idle — a top-level-only check can read 'idle' and the restart
    # then kills in-flight work. Killing a busy session throws away in-flight
    # context. CONSERVATIVE: any error / no transcript -> BUSY (never nuke when
    # unsure). Returns $true = busy (defer), $false = idle (safe).
    param([int]$QuietMin = 5)
    try {
        $munged = ($repo -replace '[:\\/]', '-')
        $projDir = Join-Path $env:USERPROFILE ".claude\projects\$munged"
        if (-not (Test-Path $projDir)) { return $true }  # unsure -> busy
        $newest = Get-ChildItem -Path $projDir -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newest) { return $true }               # unsure -> busy
        $quietSince = (Get-Date) - $newest.LastWriteTime
        return ($quietSince.TotalMinutes -lt $QuietMin)
    } catch { return $true }                             # unsure -> busy
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
        # Pass the resolved claude PID so the STOLEN holder-check can compare
        # ancestry in the scheduled-task context (no claude ancestor to walk).
        $wdArgs = @($watchdog, '--probe-only')
        if ($claudePid -gt 0) { $wdArgs += @('--claude-pid', "$claudePid") }
        $out = (& $pyExe @wdArgs 2>$null | Select-Object -First 1)
        if ($out) { $poller = $out.Trim() }
    } catch {}
    if ($poller -notin @('ALIVE','DEAD','UNKNOWN','STOLEN')) { $poller = 'UNKNOWN' }

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
    } elseif ($poller -in @('DEAD','STOLEN')) {
        # DEAD: poller permanently 409'd. STOLEN: slot held by a FOREIGN local
        # process (another claude's auto-started bridge) — inbound is dead even
        # though the 409 probe looks healthy; a restart reclaims the slot (the
        # thief's plugin gives up after one 409). Same idle-gated restart path.
        $action = 'restart'
    }

    # --- cold-start hygiene: is a previous cold-start launcher still running? -
    # Start-BotCold records the launcher pid + start time. Younger than
    # LauncherGraceMin -> it's still inside its (now-bounded) pre-launch steps:
    # do NOT spawn another. Older and still no bot -> hung: kill its tree,
    # clear the record, fall through to the normal cap check below. Without
    # this, any stall between the launcher starting and claude coming up (a
    # bounded step still eating its full timeout, an OS hiccup, etc.) would
    # spawn a fresh cold-start launcher on every tick on top of the stuck one.
    if ($action -eq 'cold-start') {
        $st = Read-BotState
        $lpid = 0; $lageMin = 1e9
        if ($st) {
            if ($null -ne $st.launcher_pid) { try { $lpid = [int]$st.launcher_pid } catch {} }
            $lstart = [datetime]::MinValue
            if ($st.launcher_started_at -and [datetime]::TryParse("$($st.launcher_started_at)", [ref]$lstart)) {
                $lageMin = ((Get-Date) - $lstart).TotalMinutes
            }
        }
        if ($lpid -gt 0 -and (Test-ProcAlive $lpid @('pwsh','powershell'))) {
            if ($lageMin -lt $LauncherGraceMin) {
                Write-SupLog "cold-start in progress (launcher pid $lpid, age $([int]($lageMin * 60))s) - not spawning another"
                exit 0
            }
            if ($DryRun) { Write-SupLog "DRYRUN would kill hung launcher pid $lpid (age $([int]$lageMin)m)"; exit 0 }
            & taskkill /PID $lpid /T /F 2>$null | Out-Null
            Write-SupLog "launcher HUNG after $([int]$lageMin)m (pid $lpid) -> killed tree (exit=$LASTEXITCODE)"
            Write-BotState @{ launcher_pid = $null; launcher_started_at = $null }
        } elseif (($lpid -gt 0 -or $lageMin -lt 1e9) -and -not $DryRun) {
            Write-BotState @{ launcher_pid = $null; launcher_started_at = $null }   # dead/stale record
        }
    }

    # --- heartbeat: due-commitments surfacing (isolated) ----------------------
    Invoke-CommitmentsHeartbeat -AsDryRun:$DryRun

    # --- login-session expiry watch (isolated; never gates liveness) ----------
    Invoke-SessionExpiryMonitor -AsDryRun:$DryRun

    # --- live quota probe (isolated; never gates liveness). Keeps the statusline
    # number fresh and warns BEFORE the wall. Self-throttled to one API call/5min.
    Invoke-UsageProbe -AsDryRun:$DryRun

    # --- alerts.log triage tick (isolated; never gates liveness). Every
    # BOT_TRIAGE_EVERY_MIN, idle-gated: classify new alerts, spawn one detached
    # headless fix-or-card run when there is something new. NO_REPLY by default.
    Invoke-AlertTriage -AsDryRun:$DryRun

    if ($action -eq 'none') {
        # Healthy: run the hourly-gated monitors here (never on the restart/
        # cold-start paths, so monitor latency can't delay recovery).
        Invoke-MonitorTick -AsDryRun:$DryRun
        # Secrets backup push: periodic (launch-only push goes stale on a
        # long-running session). sync_settings.sh self-gates (BOT_PUSH_MIN_INTERVAL,
        # default 6h) so this is a cheap no-op on most ticks. Push-only by design —
        # pull is manual DR. Isolated, fail-open; healthy path only.
        if (-not $DryRun) {
            try {
                $gitBash = 'C:\Program Files\Git\bin\bash.exe'
                $syncSh  = Join-Path $repo 'tools\infra\sync_settings.sh'
                if ((Test-Path $gitBash) -and (Test-Path $syncSh)) {
                    $out = & $gitBash $syncSh push 2>&1 | Select-Object -Last 1
                    if ($out -and "$out" -notmatch 'push skipped') {
                        Write-SupLog "secrets-push: $out"
                    }
                }
            } catch { Write-SupLog "secrets-push: swallowed (fail-open): $($_.Exception.Message)" }
        }
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
        # NEVER kill a live session that's actively working. The restart path
        # kills claude to relaunch (to recover a dead/stolen poller) — but if the
        # session is mid-task, that -Force kill throws away in-flight context.
        # Idle-gate it: a BUSY session is DEFERRED + TG-alerted, not killed.
        # Poller recovery waits until the session goes quiet (or the operator
        # acts). Long-running context is load-bearing. Fail-open: unsure -> busy.
        if (Test-SessionBusy) {
            Write-SupLog "restart DEFERRED: poller $poller but session BUSY (transcript fresh) — not killing live work"
            # TG-alert at most once per 2h (ticks are frequent; alerting each
            # tick would spam). A stamp file gates it.
            try {
                $stamp = Join-Path $repo '.claude\.alert_poller_defer.ts'
                $due = $true
                if (Test-Path $stamp) {
                    $last = [datetime]::MinValue
                    if ([datetime]::TryParse((Get-Content $stamp -Raw -ErrorAction SilentlyContinue), [ref]$last)) {
                        if (((Get-Date) - $last).TotalHours -lt 2) { $due = $false }
                    }
                }
                if ($due) {
                    $env:PYTHONIOENCODING = 'utf-8'
                    $msg = "⚠️ TG poller $poller but your session is actively working — supervisor is NOT restarting (would lose context). Inbound is down; it auto-heals the moment the session goes idle."
                    & $pyExe (Join-Path $repo 'tools\tg\tg_send.py') $msg 2>&1 | Out-Null
                    # Stamp only after a ZERO-exit send — stamping first would
                    # suppress the alert for 2h even when the send failed.
                    if ($LASTEXITCODE -eq 0) {
                        [System.IO.File]::WriteAllText($stamp, (Get-Date).ToString('o'))
                    }
                }
            } catch {}
            exit 0
        }
        if ($claudePid -le 0) {
            # PID-0 footgun: restart-bot -OldPid 0 waits on the System Idle
            # Process ("alive"), times out and refuses to relaunch — while we'd
            # have already killed the owner shell below. Net result: bot down
            # until a FRESH cold-start = context loss. Without a real claude PID,
            # defer this tick; the CIM child query normally resolves it next tick.
            Write-SupLog "restart DEFERRED: claudePid unresolved (0) — not spawning restart-bot with OldPid 0"
            exit 0
        }
        Write-SupLog "ACTION=START kind=restart (poller $poller, bot proc alive, session idle -> --continue)"
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
