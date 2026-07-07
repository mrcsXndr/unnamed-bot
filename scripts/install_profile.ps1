# install_profile.ps1 — add a one-word launch command to your PowerShell profile.
#
# After this runs, open a NEW PowerShell window and just type:
#     bot
# (or the alias named after your bot) to start the long-running conversation —
# no need to remember `pwsh -File scripts\launch.ps1` or where the repo lives.
#
# Idempotent: the command lives in a MANAGED BLOCK between markers, so re-running
# replaces only that block and never touches the rest of your profile.
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File scripts\install_profile.ps1
#   pwsh -File scripts\install_profile.ps1 -AliasName goosey   # extra alias name
#   pwsh -File scripts\install_profile.ps1 -DryRun             # print, change nothing

param(
    [string]$AliasName = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

function Note { param([string]$m) Write-Host "  $m" -ForegroundColor DarkGray }

# --- resolve the alias name -----------------------------------------------------
# Priority: -AliasName arg > BOT_NAME in .env > "bot". Sanitize to a valid
# PowerShell command name (letters/digits/_/-, must start with a letter).
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

if (-not $AliasName) { $AliasName = Get-DotEnvValue 'BOT_NAME' }
if ($AliasName) {
    # keep letters/digits/underscore/dash; drop the rest; must start with a letter
    $AliasName = ($AliasName -replace '[^A-Za-z0-9_-]', '').TrimStart('-', '_', '0','1','2','3','4','5','6','7','8','9')
}
if (-not $AliasName) { $AliasName = 'bot' }
$AliasName = $AliasName.ToLower()

Write-Host ""
Write-Host "  PowerShell launch command" -ForegroundColor Cyan
Write-Host "  Repo:    $repo" -ForegroundColor DarkGray
Write-Host "  Command: bot" -NoNewline -ForegroundColor Green
if ($AliasName -ne 'bot') { Write-Host " (+ alias: $AliasName)" -ForegroundColor Green } else { Write-Host "" }
Write-Host ""

$profilePath = $PROFILE
$marker    = "# --- bot launcher (managed by install_profile.ps1) ---"
$endMarker = "# --- end bot launcher ---"

# The command wraps scripts\launch.ps1 (single source of truth for the launch
# sequence — duplicate guard, Telegram fixes, owner-lock, continue/fresh menu).
# $repo is baked in as an absolute path so the command works from any directory.
$aliasLine = if ($AliasName -ne 'bot') { "Set-Alias -Name $AliasName -Value bot" } else { '' }
$block = @"

$marker
function bot {
    param([Parameter(ValueFromRemainingArguments = `$true)] [string[]]`$Passthrough)
    `$repo = "$repo"
    if (-not (Test-Path `$repo)) {
        Write-Host "bot: repo not found at `$repo" -ForegroundColor Red
        return
    }
    & (Join-Path `$repo 'scripts\launch.ps1') @Passthrough
}
$aliasLine
$endMarker
"@

if ($DryRun) {
    Note "(dry-run) would write this managed block to: $profilePath"
    Write-Host $block
    Write-Host ""
    Note "then: open a NEW PowerShell and type 'bot'"
    exit 0
}

if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

# Strip any previous managed block, then append the fresh one (idempotent).
$current = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if ($current -and $current.Contains($marker)) {
    $pattern = [regex]::Escape($marker) + '(.|\n)*?' + [regex]::Escape($endMarker) + '\r?\n?'
    $current = [regex]::Replace($current, $pattern, '')
    Set-Content -Path $profilePath -Value $current -NoNewline
}
Add-Content -Path $profilePath -Value $block

Write-Host "  Installed into: $profilePath" -ForegroundColor Green
Write-Host "  Open a NEW PowerShell window, then type:  " -NoNewline
Write-Host "bot" -ForegroundColor Yellow
Write-Host ""
exit 0
