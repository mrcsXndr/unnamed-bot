# register-tg-watchdog.ps1 - register the TG poller watchdog as a scheduled task.
#
# Creates a Windows Scheduled Task that runs tools/v2/tg_watchdog.py every 3
# minutes. The watchdog probes the Telegram getUpdates slot; if it confirms the
# long-poller is dead it heals bridge-first (kick the poller subprocess so the
# plugin host respawns it), falling back to a detached session restart.
#
# SAFETY: idempotent (/F overwrites). Defaults to PRINT-ONLY - it shows the exact
# schtasks command and does NOT register anything unless you pass -Confirm.
#
# Usage:
#   powershell -File scripts\register-tg-watchdog.ps1            # prints only
#   powershell -File scripts\register-tg-watchdog.ps1 -Confirm   # registers

param(
    [switch]$Confirm
)

$ErrorActionPreference = 'Continue'

$taskName = 'AssistantBot-TGWatchdog'
# Absolute path so registration works even when System32 isn't on PATH
# (observed in some restricted-PATH launch shells).
$schtasksExe = Join-Path $env:SystemRoot 'System32\schtasks.exe'

# Resolve a python interpreter from PATH (no hardcoded version dir). Override
# with BOT_PYTHON if your interpreter isn't on PATH.
$pythonExe = $null
if ($env:BOT_PYTHON -and (Test-Path $env:BOT_PYTHON)) { $pythonExe = $env:BOT_PYTHON }
if (-not $pythonExe) {
    foreach ($name in @('python.exe','python3.exe','python','python3')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue
        if ($c) { $pythonExe = $c.Source; break }
    }
}
if (-not $pythonExe) { $pythonExe = 'python' }

# Repo root = parent of this scripts/ dir (no hardcoded user path).
$repo = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repo 'tools\v2\tg_watchdog.py'

# schtasks needs the whole TR as one quoted string; inner quotes escape the paths.
$tr = "`"$pythonExe`" `"$script`""

$schtasksArgs = @(
    '/Create',
    '/TN', $taskName,
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

Write-Host "Registering scheduled task '$taskName'..." -ForegroundColor Green
& $schtasksExe @schtasksArgs
if ($LASTEXITCODE -eq 0) {
    Write-Host "Registered. Query with: schtasks /Query /TN $taskName" -ForegroundColor Green
} else {
    Write-Host "schtasks exited $LASTEXITCODE - task may not have been created." -ForegroundColor Red
}
exit $LASTEXITCODE
