# create_shortcuts.ps1 — double-click launchers for people who never touch a CLI.
#
# Creates two shortcuts (Desktop + Start Menu) so you can start the bot without
# opening a terminal or knowing any commands:
#   "<BotName>"              -> resumes the long-running conversation (--continue)
#   "<BotName> (new chat)"   -> starts a fresh session
#
# Both open a PowerShell window that STAYS OPEN (-NoExit) so you can watch the
# bot and talk to it in the terminal too; Telegram works in parallel.
#
# Idempotent: overwrites existing shortcuts of the same name.
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File scripts\create_shortcuts.ps1
#   pwsh -File scripts\create_shortcuts.ps1 -BotName "Goosey"
#   pwsh -File scripts\create_shortcuts.ps1 -NoNewChat   # only the resume shortcut
#   pwsh -File scripts\create_shortcuts.ps1 -NoStartMenu # desktop only
#   pwsh -File scripts\create_shortcuts.ps1 -DryRun

param(
    [string]$BotName = '',
    [switch]$NoNewChat,
    [switch]$NoStartMenu,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent

function Note { param([string]$m) Write-Host "  $m" -ForegroundColor DarkGray }

# --- bot name (for the shortcut label) -----------------------------------------
function Get-DotEnvValue {
    param([string]$Key)
    $envFile = Join-Path $repo '.env'
    if (-not (Test-Path $envFile)) { return $null }
    foreach ($line in Get-Content $envFile -ErrorAction SilentlyContinue) {
        if ($line -match "^\s*$Key\s*=\s*(.+?)\s*$") {
            $val = $matches[1].Trim('"').Trim("'")
            if ($val -and $val -notmatch 'YOUR_.*_HERE') { return $val }
        }
    }
    return $null
}
if (-not $BotName) { $BotName = Get-DotEnvValue 'BOT_NAME' }
if (-not $BotName) { $BotName = 'Bot' }
# strip characters Windows forbids in a file name
$safeName = ($BotName -replace '[\\/:*?"<>|]', '').Trim()
if (-not $safeName) { $safeName = 'Bot' }

# --- pick the shell that runs the launcher -------------------------------------
# Prefer pwsh (PowerShell 7); fall back to Windows PowerShell 5.1 which always
# exists. The shortcut target is the shell; -File points at launch.ps1.
#
# IMPORTANT: pick a STABLE path. `(Get-Command pwsh).Source` on a Store install
# resolves to a VERSIONED WindowsApps dir (…PowerShell_7.6.3.0…) that changes on
# every pwsh update — baking it into a .lnk means the shortcut silently breaks
# after the next update. Prefer, in order: the Store execution-alias shim (a
# stable reparse point), a non-versioned Program Files install, then whatever
# `pwsh` resolves to, then Windows PowerShell 5.1.
$shell = $null
$candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),   # stable Store alias
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')             # stable MSI install
)
foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $shell = $c; break } }
if (-not $shell) {
    $resolved = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    # reject a versioned WindowsApps path — it won't survive a pwsh update
    if ($resolved -and $resolved -notmatch 'WindowsApps\\Microsoft\.PowerShell_') { $shell = $resolved }
}
if (-not $shell) { $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$launch = Join-Path $repo 'scripts\launch.ps1'

Write-Host ""
Write-Host "  Desktop shortcuts" -ForegroundColor Cyan
Write-Host "  Bot:   $safeName" -ForegroundColor DarkGray
Write-Host "  Shell: $shell" -ForegroundColor DarkGray
Write-Host ""

# targets: (fileName, launchMode, description)
$targets = @(
    @{ Name = $safeName;               Mode = '-Continue'; Desc = "Resume the long-running $safeName conversation" }
)
if (-not $NoNewChat) {
    $targets += @{ Name = "$safeName (new chat)"; Mode = '-Fresh'; Desc = "Start a fresh $safeName session" }
}

$locations = @([Environment]::GetFolderPath('Desktop'))
if (-not $NoStartMenu) {
    $startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) $safeName
    $locations += $startMenu
}

if ($DryRun) {
    foreach ($loc in $locations) {
        foreach ($t in $targets) {
            Note "(dry-run) would create: $(Join-Path $loc ($t.Name + '.lnk'))"
            Note "    target : $shell"
            Note "    args   : -NoExit -ExecutionPolicy Bypass -File `"$launch`" $($t.Mode)"
            Note "    workdir: $repo"
        }
    }
    exit 0
}

$shellObj = New-Object -ComObject WScript.Shell
$made = 0
foreach ($loc in $locations) {
    if (-not (Test-Path $loc)) { New-Item -ItemType Directory -Force -Path $loc | Out-Null }
    foreach ($t in $targets) {
        try {
            $lnkPath = Join-Path $loc ($t.Name + '.lnk')
            $sc = $shellObj.CreateShortcut($lnkPath)
            $sc.TargetPath       = $shell
            $sc.Arguments        = "-NoExit -ExecutionPolicy Bypass -File `"$launch`" $($t.Mode)"
            $sc.WorkingDirectory = $repo
            $sc.Description       = $t.Desc
            $sc.IconLocation      = "$shell,0"
            $sc.Save()
            Write-Host "  created: $lnkPath" -ForegroundColor Green
            $made++
        } catch {
            Note "failed: $($t.Name) -> $($_.Exception.Message)"
        }
    }
}
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shellObj)

Write-Host ""
if ($made -gt 0) {
    Write-Host "  Done — double-click `"$safeName`" on your Desktop to start the bot." -ForegroundColor Green
} else {
    Write-Host "  No shortcuts were created (see errors above)." -ForegroundColor Yellow
}
Write-Host ""
exit 0
