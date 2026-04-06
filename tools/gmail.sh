#!/usr/bin/env bash
# Gmail CLI wrapper
# Usage:
#   gmail.sh priority           # Unread from priority domains
#   gmail.sh unread              # All unread
#   gmail.sh search "query"     # Search emails
#   gmail.sh recent [count]     # Recent emails (default 10)

set -euo pipefail

PYTHON="${PYTHON:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python)}"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/google_workspace.py"
export PYTHONIOENCODING=utf-8

CMD="${1:-priority}"

case "$CMD" in
  priority)
    "$PYTHON" "$SCRIPT" gmail-priority
    ;;
  unread)
    "$PYTHON" "$SCRIPT" gmail-unread
    ;;
  search)
    QUERY="${2:?Usage: gmail.sh search \"query\"}"
    "$PYTHON" "$SCRIPT" gmail-search "$QUERY"
    ;;
  recent)
    COUNT="${2:-10}"
    "$PYTHON" "$SCRIPT" gmail-recent "$COUNT"
    ;;
  *)
    echo "Usage: gmail.sh {priority|unread|search|recent}"
    ;;
esac
