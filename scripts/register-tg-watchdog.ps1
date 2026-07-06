# register-tg-watchdog.ps1 — register the Telegram poller watchdog task.
#
# Windows-only, OPTIONAL. If you run the supervisor (register-supervisor.ps1)
# you do NOT need this — the supervisor already probes the poller every tick.
# This standalone task exists for setups that want poller auto-heal WITHOUT
# the full supervisor daemon.
#
# Creates a Windows Scheduled Task that runs tools/v2/tg_watchdog.py every 3
# minutes. The watchdog probes the Telegram getUpdates slot; if it confirms
# the long-poller is dead AND the session is idle, it triggers a detached
# restart that re-acquires the poller lock.
#
# SAFETY: idempotent (/F overwrites). Defaults to PRINT-ONLY — it shows the
# exact schtasks command and does NOT register anything unless you pass
# -Confirm.
#
# Usage:
#   pwsh -File scripts\register-tg-watchdog.ps1            # prints only
#   pwsh -File scripts\register-tg-watchdog.ps1 -Confirm   # registers

param(
    [switch]$Confirm,
    [string]$TaskName = 'ClaudeBot-TG-Watchdog'
)

$ErrorActionPreference = 'Continue'

# Absolute path so registration works even when System32 isn't on PATH.
$schtasksExe = Join-Path $env:SystemRoot 'System32\schtasks.exe'
$pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pythonExe) { $pythonExe = 'python' }
$repo = Split-Path $PSScriptRoot -Parent
$script = Join-Path $repo 'tools\v2\tg_watchdog.py'

# schtasks needs the whole TR as one quoted string; inner quotes escape the paths.
$tr = "`"$pythonExe`" `"$script`""

$schtasksArgs = @(
    '/Create',
    '/TN', $TaskName,
    '/SC', 'MINUTE',
    '/MO', '3',
    '/TR', $tr,
    '/F'
)

# Human-readable echo of the exact command.
$printable = 'schtasks ' + (($schtasksArgs | ForEach-Object {
    if ($_ -match '\s') { "`"$_`"" } else { $_ }
}) -join ' ')

if (-not $Confirm) {
    Write-Host 'DRY-RUN (no -Confirm): would register the scheduled task with:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  $printable" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Re-run with -Confirm to actually create the task.' -ForegroundColor DarkGray
    exit 0
}

Write-Host "Registering scheduled task '$TaskName'..." -ForegroundColor Green
& $schtasksExe @schtasksArgs
if ($LASTEXITCODE -eq 0) {
    Write-Host "Registered. Query with: schtasks /Query /TN $TaskName" -ForegroundColor Green
} else {
    Write-Host "schtasks exited $LASTEXITCODE - task may not have been created." -ForegroundColor Red
}
exit $LASTEXITCODE
