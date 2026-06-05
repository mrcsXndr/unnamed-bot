# launch.ps1 — one-command startup for the bot on Windows.
#
# Run: powershell -ExecutionPolicy Bypass -File scripts\launch.ps1
# (or wire up a `mybot` function in $PROFILE — see README "One-line launcher".)
#
# What it does:
#   1. Clones the repo from the public URL if it isn't there yet.
#   2. Optionally pulls your latest secrets/settings from a sync folder.
#   3. Makes the Telegram channel plugin work on Windows (two known gotchas
#      — see comments below). Both steps gracefully no-op if you don't use Telegram.
#   4. Asks whether to CONTINUE the last session or start a NEW one.
#   5. Launches Claude Code with the Telegram channel plugin attached.

$ErrorActionPreference = "Stop"

# --- 1. Repo location: clone if missing -------------------------------------
$repo = "C:\Users\$env:USERNAME\Code\my-bot"
if (-not (Test-Path $repo)) {
    Write-Host "Cloning bot into $repo ..." -ForegroundColor Cyan
    git clone https://github.com/mrcsXndr/unnamed-bot.git $repo
}
Set-Location $repo

# --- 2. Optional: pull settings from a sync folder --------------------------
# If you keep secrets/settings in a cloud/USB folder (see README "Multi-machine
# sync"), set SYNC_DRIVE_PATH and this pulls the latest copy on the way in.
# sync_settings.sh is a bash script, so run it through Git Bash.
$gitBash = "C:\Program Files\Git\bin\bash.exe"
if ($env:SYNC_DRIVE_PATH -and (Test-Path "$repo\tools\sync_settings.sh") -and (Test-Path $gitBash)) {
    Write-Host "Pulling latest settings from sync folder..." -ForegroundColor Cyan
    & $gitBash "$repo\tools\sync_settings.sh" pull 2>$null
}

# --- 3. Telegram channel plugin: Windows fixes ------------------------------
# These make `--channels plugin:telegram@claude-plugins-official` actually work
# on Windows. Both are no-ops if the plugin isn't installed or you don't use
# Telegram, so the bot still launches fine without it.

# Read TELEGRAM_BOT_TOKEN out of the repo .env (if present).
$botToken = $null
$envFile = "$repo\.env"
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$') {
            $val = $matches[1].Trim('"').Trim("'")
            # Ignore the placeholder shipped in .env.example.
            if ($val -and $val -notmatch 'YOUR_.*_HERE') { $botToken = $val }
        }
    }
}

# The telegram plugin keeps its own state dir under the Claude plugins cache.
$pluginRoot = "$env:USERPROFILE\.claude\plugins"
$tgStateDir = Join-Path $pluginRoot "claude-plugins-official\telegram"
$tgPluginDir = $null
if (Test-Path $tgStateDir) {
    $tgPluginDir = $tgStateDir
} else {
    # Layout varies by Claude Code version; find any telegram plugin dir.
    if (Test-Path $pluginRoot) {
        $found = Get-ChildItem -Path $pluginRoot -Recurse -Directory -Filter "telegram" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $tgPluginDir = $found.FullName }
    }
}

if ($tgPluginDir) {
    # Fix A: write the bot token into the plugin's state .env as LF-only.
    # WHY: the plugin's runtime is bun, and bun reads a trailing CRLF "\r" into
    # the token value, which then fails Telegram auth with a confusing 401.
    # We must write "\n" line endings explicitly — Out-File/Set-Content emit CRLF
    # on Windows, so use [IO.File]::WriteAllText.
    if ($botToken) {
        $tgEnv = Join-Path $tgPluginDir ".env"
        [IO.File]::WriteAllText($tgEnv, "TELEGRAM_BOT_TOKEN=$botToken`n")
    }

    # Fix B: point the plugin's MCP config at an absolute bun.exe path.
    # WHY: the plugin's .mcp.json runs "command":"bun", but Windows PATH often
    # can't resolve a bare 'bun' for the spawned MCP process, so the channel
    # silently fails to start. Rewrite it to the absolute bun.exe once.
    $bunExe = "$env:USERPROFILE\.bun\bin\bun.exe"
    $mcpJson = Join-Path $tgPluginDir ".mcp.json"
    if ((Test-Path $mcpJson) -and (Test-Path $bunExe)) {
        $mcpRaw = Get-Content $mcpJson -Raw
        # Only patch if it still references bare 'bun' (idempotent).
        if ($mcpRaw -match '"command"\s*:\s*"bun"') {
            $escaped = $bunExe.Replace('\', '\\')
            $patched = $mcpRaw -replace '"command"\s*:\s*"bun"', "`"command`": `"$escaped`""
            [IO.File]::WriteAllText($mcpJson, $patched)
            Write-Host "Patched telegram plugin to use $bunExe" -ForegroundColor DarkGray
        }
    }
}

# --- 4. Continue-or-new prompt ----------------------------------------------
Write-Host ""
Write-Host "  [1] Continue last session" -ForegroundColor Green
Write-Host "  [2] Start fresh session"   -ForegroundColor Green
Write-Host ""
$choice = Read-Host "Choose"

# --- 5. Launch with the Telegram channel plugin -----------------------------
$channels = @("--channels", "plugin:telegram@claude-plugins-official")

if ($choice -eq "2") {
    claude --dangerously-skip-permissions @channels @args
} else {
    claude --dangerously-skip-permissions --continue @channels @args
}
