# smoke_test.ps1 — Windows wrapper for the harness smoke test.
# Finds Git Bash and runs scripts/smoke_test.sh with it (the test itself is
# a portable bash script; Git Bash ships with git, a required dependency).
#
# Usage: pwsh -ExecutionPolicy Bypass -File scripts\smoke_test.ps1

$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$test = Join-Path $repo 'scripts\smoke_test.sh'

# Resolve bash: PATH first, then the standard Git-for-Windows locations.
$bash = $null
$cmd = Get-Command bash -ErrorAction SilentlyContinue
if ($cmd) { $bash = $cmd.Source }
if (-not $bash) {
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )) {
        if ($candidate -and (Test-Path $candidate)) { $bash = $candidate; break }
    }
}
if (-not $bash) {
    Write-Host 'smoke_test: bash not found. Install git (scripts\install_deps.ps1) — Git Bash ships with it.'
    exit 1
}

& $bash $test
exit $LASTEXITCODE
