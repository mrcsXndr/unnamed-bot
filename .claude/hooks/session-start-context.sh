#!/usr/bin/env bash
# SessionStart hook: inject last session summary + git context
cd "$(dirname "$0")/../.." || exit 0

# Invalidate statusline cost cache
rm -f "$HOME/.claude/api_cost_cache.json" 2>/dev/null

SESSION_LOG="context/session-log.md"
LAST_SESSION=""
if [ -f "$SESSION_LOG" ]; then
  LAST_SESSION=$(awk '/^## /{found++} found==1' "$SESSION_LOG" 2>/dev/null | head -10)
fi

GIT_LOG=$(git log --oneline -5 2>/dev/null || echo "")

CONTEXT=""
if [ -n "$LAST_SESSION" ]; then CONTEXT="Last session:\n$LAST_SESSION"; fi
if [ -n "$GIT_LOG" ]; then CONTEXT="$CONTEXT\n\nRecent commits:\n$GIT_LOG"; fi

if [ -n "$CONTEXT" ]; then
  ESCAPED=$(printf '%s' "$CONTEXT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":$ESCAPED}}"
fi
