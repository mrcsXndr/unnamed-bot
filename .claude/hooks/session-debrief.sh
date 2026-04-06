#!/usr/bin/env bash
# Stop hook: background subagent reviews session and updates context docs
# Runs async — does not block the user's exit

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR" || exit 0

SESSION_LOG="context/session-log.md"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

INPUT=$(cat 2>/dev/null || echo '{}')

RECENT_CHANGES=$(git log --oneline -10 2>/dev/null || echo "no git history")
CHANGED_FILES=$(git diff --name-only HEAD~3 HEAD 2>/dev/null | head -20 || echo "unknown")

PROMPT="You are a session debrief agent. Your job is to:
1. Append a SHORT (3-5 line) entry to context/session-log.md
2. Check if any context docs need updating
3. Commit changes with 'chore(auto): session debrief update'

Recent git log:
$RECENT_CHANGES

Changed files:
$CHANGED_FILES

Format:
## $TIMESTAMP
- **Task:** [what was done]
- **Decisions:** [key decisions]
- **Open:** [pending items]

Rules: keep SHORT, only update docs if meaningful, commit silently, no push"

nohup claude --print --model sonnet --dangerously-skip-permissions -p "$PROMPT" \
  > /dev/null 2>&1 &

# Auto-sync on stop
if [ -n "${SYNC_DRIVE_PATH:-}" ] && [ -d "${SYNC_DRIVE_PATH}" ]; then
  bash "$PROJECT_DIR/tools/sync_settings.sh" push 2>/dev/null || true
fi

exit 0
