#!/usr/bin/env bash
# Launch Chrome with remote debugging so the bot can drive it via tools/browser.py
# Run: bash scripts/chrome_debug.sh
#
# Uses your normal Chrome profile, so the bot drives YOUR logged-in session.
set -euo pipefail

PORT=9222

# Already running with the debug port?
if curl -fsS "http://localhost:${PORT}/json/version" >/dev/null 2>&1; then
  echo "Chrome already running with debug port ${PORT}."
  exit 0
fi

# Find a Chrome binary
CHROME=""
for cand in \
  "${CHROME_EXE:-}" \
  "google-chrome" \
  "google-chrome-stable" \
  "chromium" \
  "chromium-browser" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
  if [ -n "$cand" ] && command -v "$cand" >/dev/null 2>&1; then CHROME="$cand"; break; fi
  if [ -n "$cand" ] && [ -x "$cand" ]; then CHROME="$cand"; break; fi
done

if [ -z "$CHROME" ]; then
  echo "ERROR: Could not find Chrome/Chromium. Set CHROME_EXE to its path." >&2
  exit 1
fi

echo "Launching Chrome with remote debugging on port ${PORT}..."
"$CHROME" --remote-debugging-port="${PORT}" >/dev/null 2>&1 &
sleep 3
echo "Chrome launched. The bot can now connect via tools/browser.py."
