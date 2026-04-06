#!/usr/bin/env bash
# Play "job's done" sound on session stop
SOUND="$(dirname "$0")/sounds/goose-done.m4a"
if [ -f "$SOUND" ]; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    Add-Type -AssemblyName PresentationCore
    \$player = New-Object System.Windows.Media.MediaPlayer
    \$player.Open([uri]::new('$(cygpath -w "$SOUND")'))
    \$player.Play()
    Start-Sleep -Seconds 3
  " &>/dev/null &
fi
