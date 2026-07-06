# resource_monitor.ps1 — local resource + stray-process janitor for the bot's box.
#
# Baseline: only the bot + what it needs should be running. This watches for
# the bot's OWN exhaust (stray automation browsers, abandoned render procs,
# duplicate pollers) and reports/cleans it. It NEVER touches the user's own
# apps, work, or games — only bot-spawned automation.
#
# Usage:  pwsh -File tools/infra/resource_monitor.ps1 [-Clean]
#   -Clean : auto-kill stray agent-browser "Chrome for Testing" orphans (safe:
#            isolated browser, no user data). Other strays are reported, not killed.
# Output: one compact JSON object on stdout. Fail-open (errors never throw).

param(
  [switch]$Clean,
  [switch]$Tg,                 # self-alert to Telegram on warn/critical (cooldown dedup)
  [int]$AbKillThreshold = 10,  # agent-browser chrome count above this = orphan pile -> clean
  [int]$TgCooldownH = 6        # don't re-alert the SAME issue set within this many hours
)

$ErrorActionPreference = 'SilentlyContinue'
$issues  = @()
$actions = @()

function Add-Issue($sev,$cat,$detail){ $script:issues += ,([ordered]@{ sev=$sev; cat=$cat; detail=$detail }) }

# --- GPU (NVIDIA) ---
$gpu = $null
$smi = "$env:SystemRoot\System32\nvidia-smi.exe"
if (Test-Path $smi) {
  try {
    $g = (& $smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null) -split ','
    if ($g.Count -ge 4) {
      $gpu = [ordered]@{ util=[int]$g[0].Trim(); temp=[int]$g[1].Trim(); mem_used_mb=[int]$g[2].Trim(); mem_total_mb=[int]$g[3].Trim() }
      # GPU temp is TELEMETRY ONLY — high temp may be the user's own games/work,
      # not the bot. The bot-attributable runaway signal is a stray render/
      # pipeline proc (detected below), not temperature on its own.
    }
  } catch {}
}

# --- agent-browser "Chrome for Testing" orphans (the bot's automation browser) ---
$ab = Get-Process -Name chrome -EA SilentlyContinue | Where-Object { $_.Path -like '*\.agent-browser\*' }
$abCount = @($ab).Count
$abMem = if ($abCount) { [math]::Round((($ab | Measure-Object WorkingSet -Sum).Sum)/1MB,0) } else { 0 }
if ($abCount -gt 0) {
  if ($abCount -gt $AbKillThreshold) {
    Add-Issue 'warn' 'browser' "$abCount stray agent-browser Chrome procs ($abMem MB) — orphan pile"
    if ($Clean) { $ab | Stop-Process -Force -EA SilentlyContinue; $actions += "killed $abCount agent-browser Chrome orphans (${abMem}MB freed)" }
  } else {
    Add-Issue 'info' 'browser' "$abCount agent-browser Chrome procs ($abMem MB) — within one active session"
  }
}

# --- stray capture-pipeline procs (edit for your own workloads) ---
foreach ($n in 'brush','colmap') {
  $p = Get-Process -Name $n -EA SilentlyContinue
  if ($p) { Add-Issue 'warn' 'pipeline' "$(@($p).Count) '$n' proc(s) running — stray splat-pipeline render?" }
}
$ff = Get-Process -Name ffmpeg -EA SilentlyContinue
if (@($ff).Count -gt 0) { Add-Issue 'info' 'pipeline' "$(@($ff).Count) ffmpeg proc(s) — stray if no capture running" }

# --- duplicate bot sessions / pollers (single-poller invariant) ---
$claudeCount = @(Get-Process -Name claude -EA SilentlyContinue).Count
if ($claudeCount -gt 1) { Add-Issue 'warn' 'bot' "$claudeCount claude procs — duplicate session / dual-poller risk" }

# --- stray node dev servers (vite left running) ---
$nodeCount = @(Get-Process -Name node -EA SilentlyContinue).Count
if ($nodeCount -gt 4) { Add-Issue 'info' 'node' "$nodeCount node procs — possible stray vite/dev servers" }

# --- system RAM ---
$memPct = $null
try {
  $os = Get-CimInstance Win32_OperatingSystem -EA SilentlyContinue
  if ($os) {
    $memPct = [math]::Round(100*(1-($os.FreePhysicalMemory/$os.TotalVisibleMemorySize)),0)
    if ($memPct -ge 92) { Add-Issue 'warn' 'mem' "RAM ${memPct}% used" }
  }
} catch {}

# --- C: free space (low disk breaks writes/hooks/journal — affects the bot directly) ---
$cFreeGb = $null
try {
  $cd = Get-PSDrive C -EA SilentlyContinue
  if ($cd) {
    $cFreeGb = [math]::Round($cd.Free/1GB,1)
    if     ($cFreeGb -lt 3) { Add-Issue 'critical' 'disk' "C: only ${cFreeGb}GB free — bot writes will start failing (clean up disk)" }
    elseif ($cFreeGb -lt 8) { Add-Issue 'warn'     'disk' "C: ${cFreeGb}GB free — low, clean up soon" }
  }
} catch {}

$worst = 'none'
foreach ($s in @('critical','warn','info')) { if ($issues | Where-Object { $_.sev -eq $s }) { $worst = $s; break } }

$result = [ordered]@{
  ts                   = (Get-Date).ToUniversalTime().ToString('o')
  gpu                  = $gpu
  agent_browser_chrome = $abCount
  agent_browser_mem_mb = $abMem
  claude_procs         = $claudeCount
  node_procs           = $nodeCount
  ram_pct              = $memPct
  c_free_gb            = $cFreeGb
  worst_severity       = $worst
  issue_count          = @($issues).Count
  issues               = @($issues)
  actions              = @($actions)
}

# --- optional TG self-alert (-Tg): warn/critical only, with same-issue cooldown ---
# The monitor alerts itself so the (durable) caller stays thin. Fail-open: a TG/state failure never throws and never blocks the JSON.
if ($Tg -and ($worst -in @('warn','critical'))) {
  try {
    $stateF = Join-Path $PSScriptRoot '.resource_monitor_state.json'
    $sig = (@($issues) | ForEach-Object { "$($_.sev):$($_.cat):$($_.detail)" }) -join '||'
    $now = (Get-Date).ToUniversalTime()
    $skip = $false
    if (Test-Path $stateF) {
      try {
        $prev = Get-Content $stateF -Raw | ConvertFrom-Json
        if ($prev.sig -eq $sig -and $prev.last) {
          if ((($now - [datetime]$prev.last)).TotalHours -lt $TgCooldownH) { $skip = $true }
        }
      } catch {}
    }
    if (-not $skip) {
      $lines = (@($issues) | ForEach-Object { "- [$($_.sev)] $($_.detail)" }) -join "`n"
      $msg = "Box health ($worst):`n$lines"
      $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent  # tools/infra -> repo
      $py = (Get-Command python -ErrorAction SilentlyContinue).Source
      if (-not $py) { $py = 'python' }
      $tgSend = Join-Path $repo 'tools\tg\tg_send.py'
      $env:PYTHONIOENCODING = 'utf-8'
      & $py $tgSend $msg 2>$null | Out-Null
      @{ sig = $sig; last = $now.ToString('o') } | ConvertTo-Json | Out-File -FilePath $stateF -Encoding utf8
    }
  } catch {}
}

$result | ConvertTo-Json -Depth 6 -Compress
