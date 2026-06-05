# Launch Chrome with remote debugging so the bot can drive it via tools/browser.py
# Run: powershell -ExecutionPolicy Bypass -File scripts\chrome_debug.ps1
#
# This uses your normal Chrome user-data-dir, so the bot drives YOUR logged-in
# session (your cookies, your extensions). Nothing is sent anywhere.

$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$userDataDir = "$env:LOCALAPPDATA\Google\Chrome\User Data"

# Already running with the debug port?
$debugCheck = try { Invoke-WebRequest -Uri "http://localhost:9222/json/version" -UseBasicParsing -TimeoutSec 2 } catch { $null }

if ($debugCheck) {
    Write-Host "Chrome already running with debug port 9222." -ForegroundColor Green
    $version = ($debugCheck.Content | ConvertFrom-Json).'Browser'
    Write-Host "  Browser: $version"
} else {
    # Running without the debug port? You must close it first.
    $chromeProc = Get-Process chrome -ErrorAction SilentlyContinue
    if ($chromeProc) {
        Write-Host "WARNING: Chrome is running WITHOUT the debug port." -ForegroundColor Yellow
        Write-Host "  Close all Chrome windows first, then re-run this script." -ForegroundColor Yellow
        Write-Host "  Or add --remote-debugging-port=9222 to your Chrome shortcut." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "Launching Chrome with remote debugging on port 9222..." -ForegroundColor Cyan
    Start-Process $chromePath -ArgumentList "--remote-debugging-port=9222", "--user-data-dir=`"$userDataDir`""
    Start-Sleep -Seconds 3
    Write-Host "Chrome launched. The bot can now connect via tools/browser.py." -ForegroundColor Green
}
