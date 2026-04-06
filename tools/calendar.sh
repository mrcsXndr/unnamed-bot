#!/usr/bin/env bash
# Google Calendar CLI wrapper
# Usage:
#   calendar.sh today          # Today's events
#   calendar.sh tomorrow       # Tomorrow's events
#   calendar.sh week           # This week's events
#   calendar.sh next           # Next upcoming event

set -euo pipefail

PYTHON="/c/Users/xndr/AppData/Local/Programs/Python/Python313/python.exe"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/google_workspace.py"
export PYTHONIOENCODING=utf-8

CMD="${1:-today}"

case "$CMD" in
  today)
    "$PYTHON" "$SCRIPT" calendar-today
    ;;
  tomorrow)
    "$PYTHON" "$SCRIPT" calendar-tomorrow
    ;;
  week)
    "$PYTHON" "$SCRIPT" calendar-week
    ;;
  next)
    "$PYTHON" "$SCRIPT" calendar-next
    ;;
  *)
    echo "Usage: calendar.sh {today|tomorrow|week|next}"
    ;;
esac
