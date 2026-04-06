#!/usr/bin/env bash
# Google Tasks CLI wrapper
# Usage:
#   gtasks.sh list [list_id]              # List tasks
#   gtasks.sh lists                       # List all task lists
#   gtasks.sh add "title" [--due DATE] [--list LIST_ID]  # Add task
#   gtasks.sh complete <task_id> <list_id> # Complete task

set -euo pipefail

PYTHON="/c/Users/xndr/AppData/Local/Programs/Python/Python313/python.exe"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/google_workspace.py"
export PYTHONIOENCODING=utf-8

CMD="${1:?Usage: gtasks.sh list|lists|add|complete}"

case "$CMD" in
  lists)
    "$PYTHON" "$SCRIPT" tasks-lists
    ;;
  list)
    LIST_ID="${2:-@default}"
    "$PYTHON" "$SCRIPT" tasks-list "$LIST_ID"
    ;;
  add)
    TITLE="${2:?Usage: gtasks.sh add \"title\"}"
    shift 2
    "$PYTHON" "$SCRIPT" tasks-add "$TITLE" "$@"
    ;;
  complete)
    TASK_ID="${2:?Task ID required}"
    LIST_ID="${3:-@default}"
    "$PYTHON" "$SCRIPT" tasks-complete "$TASK_ID" "$LIST_ID"
    ;;
  *)
    echo "Usage: gtasks.sh {list|lists|add|complete}"
    ;;
esac
