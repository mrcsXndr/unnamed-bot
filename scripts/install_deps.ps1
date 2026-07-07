# install_deps.ps1 — Windows dependency installer.
#
# Installs everything the bot needs, PER-COMPONENT OPT-IN:
#   git            — version control (the repo is the bot's memory)
#   node           — Node.js + npm (statusline, memory-sync, browser tooling)
#   python         — Python 3.10+ (all tools/ + hooks)
#   claude         — Claude Code CLI (official native installer) + PATH registration
#   pnpm           — package manager for node projects (via npm)
#   agent-browser  — browser-automation CLI + its own isolated Chrome (via npm)
#
# Behaviour:
#   - Already-installed components are DETECTED and skipped (idempotent).
#   - Each missing component is a separate yes/no prompt (default Yes).
#   - A failing component NEVER aborts the run — it's reported in the summary
#     and the installer moves on.
#   - Package managers: winget preferred, scoop then choco as fallbacks,
#     npm for node-global tools, the official claude.ai installer for Claude Code.
#
# Usage:
#   pwsh -ExecutionPolicy Bypass -File scripts\install_deps.ps1
#   pwsh -File scripts\install_deps.ps1 -DryRun     # print what WOULD install
#   pwsh -File scripts\install_deps.ps1 -Yes        # non-interactive: install all missing
#   pwsh -File scripts\install_deps.ps1 -Skip agent-browser,pnpm
#
# Exit codes: 0 = all good (or -DryRun); 1 = a REQUIRED component
# (git/node/python/claude) is still missing afterwards.

param(
    [switch]$Help,
    [switch]$DryRun,
    [switch]$Yes,
    [string[]]$Skip = @()
)

$ErrorActionPreference = 'Continue'

if ($Help) {
    foreach ($line in Get-Content $PSCommandPath -TotalCount 30) {
        if ($line -notmatch '^#') { break }
        Write-Output ($line -replace '^#\s?', '')
    }
    exit 0
}

function Say  { param([string]$m) Write-Host $m }
function Note { param([string]$m) Write-Host "  $m" }

function Have { param([string]$name) [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# Windows ships a fake WindowsApps `python.exe` alias that opens the Store.
# A real python answers `--version` with exit 0.
function Have-RealPython {
    foreach ($p in @('python', 'python3')) {
        $cmd = Get-Command $p -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        try {
            & $p --version *> $null
            if ($LASTEXITCODE -eq 0) { return $true }
        } catch {}
    }
    return $false
}

function Refresh-SessionPath {
    # New installs only touch the registry; pull the fresh PATH into THIS
    # session. APPEND (never replace) so process-only entries survive.
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$env:Path;$machine;$user"
    } catch {}
}

function Ensure-UserPath {
    # Idempotently add $dir to the USER PATH (registry) + current session.
    param([string]$dir)
    if ($DryRun) { Note "(dry-run) would ensure '$dir' is on the user PATH"; return }
    try {
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not (($user -split ';') -contains $dir)) {
            [Environment]::SetEnvironmentVariable('Path', ($user.TrimEnd(';') + ';' + $dir), 'User')
            Note "added '$dir' to the user PATH"
        }
    } catch { Note "could not update the user PATH: $($_.Exception.Message)" }
    if (-not (($env:Path -split ';') -contains $dir)) { $env:Path = "$dir;$env:Path" }
}

function Ask-Install {
    # Default YES — these are prerequisites, not automations.
    param([string]$name)
    if ($Yes -or $DryRun) { return $true }
    $ans = Read-Host "  Install $name? [Y/n]"
    return -not ($ans -match '^(n|no)$')
}

function Invoke-Step {
    # Dry-run-aware executor. Returns $true when the action ran (or dry-run).
    param([string]$desc, [scriptblock]$action)
    if ($DryRun) { Note "(dry-run) would: $desc"; return $true }
    Note "-> $desc"
    try { & $action; return $true } catch { Note "step failed: $($_.Exception.Message)"; return $false }
}

function Install-ViaPkgMgr {
    # winget preferred; scoop, then choco as fallbacks. Detection (not exit
    # codes) decides success, so this only needs to make a best effort.
    param([string]$wingetId, [string]$scoopPkg, [string]$chocoPkg)
    if (Have 'winget') {
        return Invoke-Step "winget install $wingetId" {
            winget install -e --id $wingetId --silent --accept-package-agreements --accept-source-agreements
        }
    }
    if (Have 'scoop') { return Invoke-Step "scoop install $scoopPkg" { scoop install $scoopPkg } }
    if (Have 'choco') { return Invoke-Step "choco install $chocoPkg" { choco install -y $chocoPkg } }
    Note 'no package manager found (winget/scoop/choco) — cannot auto-install this'
    Note 'winget ships with modern Windows 10/11; try updating "App Installer" from the Microsoft Store'
    return $false
}

function Install-NpmGlobal {
    param([string]$pkg)
    if (-not (Have 'npm')) { Note "npm not found — Node.js must be installed (and the terminal reopened) first"; return $false }
    return Invoke-Step "npm install -g $pkg" { npm install -g $pkg }
}

# --- per-component definitions ------------------------------------------------

function Detect-AgentBrowser {
    if (Have 'agent-browser') { return $true }
    if (-not (Have 'npm')) { return $false }
    try {
        $root = (& npm root -g 2>$null | Select-Object -First 1)
        return ($root -and (Test-Path (Join-Path $root 'agent-browser')))
    } catch { return $false }
}

function Get-ComponentVersion {
    param([string]$name)
    try {
        switch ($name) {
            'git'    { return (& git --version 2>$null | Select-Object -First 1) }
            'node'   { return (& node --version 2>$null | Select-Object -First 1) }
            'python' { return (& python --version 2>$null | Select-Object -First 1) }
            'pnpm'   { return (& pnpm --version 2>$null | Select-Object -First 1) }
            'claude' {
                if (Have 'claude') { return (& claude --version 2>$null | Select-Object -First 1) }
                $local = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
                if (Test-Path $local) { return (& $local --version 2>$null | Select-Object -First 1) }
            }
            'agent-browser' { return 'installed' }
        }
    } catch {}
    return ''
}

$components = @(
    @{ Name = 'git';    What = "version control; the repo is the bot's memory"
       Detect = { Have 'git' }
       Install = { Install-ViaPkgMgr 'Git.Git' 'git' 'git' } },
    @{ Name = 'node';   What = 'Node.js + npm; runs the statusline and browser tooling'
       Detect = { Have 'node' }
       Install = { Install-ViaPkgMgr 'OpenJS.NodeJS.LTS' 'nodejs-lts' 'nodejs-lts' } },
    @{ Name = 'python'; What = "Python 3.10+; runs all the bot's tools and hooks"
       Detect = { Have-RealPython }
       Install = { Install-ViaPkgMgr 'Python.Python.3.12' 'python' 'python' } },
    @{ Name = 'claude'; What = "the Claude Code CLI — the bot's brain"
       Detect = { (Have 'claude') -or (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe')) }
       Install = {
           $ok = Invoke-Step 'Claude Code native installer (claude.ai/install.ps1)' {
               Invoke-Expression (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')
           }
           # register + verify PATH regardless of the installer's own handling
           Ensure-UserPath (Join-Path $env:USERPROFILE '.local\bin')
           return $ok
       } },
    @{ Name = 'pnpm';   What = 'node package manager (used by some optional tooling)'
       Detect = { Have 'pnpm' }
       Install = { Install-NpmGlobal 'pnpm' } },
    @{ Name = 'agent-browser'; What = 'browser automation with its own isolated Chrome'
       Detect = { Detect-AgentBrowser }
       Install = {
           if (-not (Install-NpmGlobal 'agent-browser')) { return $false }
           Refresh-SessionPath
           return Invoke-Step 'agent-browser install (downloads its isolated browser)' { agent-browser install }
       } }
)

# --- main -----------------------------------------------------------------------

Say ''
Say '=== Dependency installer (Windows) ==='
if ($DryRun) { Say '    (dry-run: nothing will be installed)' }

$results = @()
foreach ($c in $components) {
    Say ''
    $name = $c.Name
    if (& $c.Detect) {
        $ver = Get-ComponentVersion $name
        Note "ok: $name already installed ($ver)"
        $results += [pscustomobject]@{ Component = $name; Status = 'already installed'; Detail = $ver }
        continue
    }
    if ($Skip -contains $name) {
        Note "skip: $name (-Skip)"
        $results += [pscustomobject]@{ Component = $name; Status = 'skipped'; Detail = '-Skip flag' }
        continue
    }
    Note "MISSING: $name — $($c.What)"
    if (-not (Ask-Install $name)) {
        $results += [pscustomobject]@{ Component = $name; Status = 'skipped'; Detail = 'declined' }
        continue
    }
    try { & $c.Install | Out-Null } catch { Note "install failed: $($_.Exception.Message)" }
    if ($DryRun) {
        $results += [pscustomobject]@{ Component = $name; Status = 'would install'; Detail = 'dry-run' }
        continue
    }
    Refresh-SessionPath
    if (& $c.Detect) {
        $ver = Get-ComponentVersion $name
        Note "installed: $name ($ver)"
        $results += [pscustomobject]@{ Component = $name; Status = 'INSTALLED'; Detail = $ver }
    } else {
        Note "FAILED: $name did not resolve after install — see output above"
        $results += [pscustomobject]@{ Component = $name; Status = 'FAILED'; Detail = 'not on PATH after install (a new terminal may fix it)' }
    }
}

# claude PATH sanity: binary present but shell can't see it -> register it
if (-not (Have 'claude')) {
    $localBin = Join-Path $env:USERPROFILE '.local\bin'
    if (Test-Path (Join-Path $localBin 'claude.exe')) { Ensure-UserPath $localBin }
}

Say ''
Say '=== Install summary ==='
foreach ($r in $results) {
    Say ("  {0,-14} {1,-18} {2}" -f $r.Component, $r.Status, $r.Detail)
}

if (-not $DryRun) {
    $requiredMissing = $false
    foreach ($req in @('git', 'node', 'claude')) {
        if (-not (Have $req)) { $requiredMissing = $true; Say "  !! required: '$req' still not resolvable" }
    }
    if (-not (Have-RealPython)) { $requiredMissing = $true; Say "  !! required: 'python' still not resolvable" }
    if ($requiredMissing) {
        Say ''
        Say 'Some required tools are still missing. If they were JUST installed,'
        Say 'open a NEW terminal (PATH refresh) and re-run:  pwsh -File scripts\setup.ps1'
        exit 1
    }
}

Say ''
Say 'All required dependencies are present.'
exit 0
