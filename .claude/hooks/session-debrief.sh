#!/usr/bin/env bash
# Stop hook: background subagent reviews session and updates context docs
# Runs async — does not block the user's exit

cd "$(dirname "$0")/../.." || exit 0

NODE="/c/Program Files/nodejs/node.exe"
PYTHON="/c/Users/xndr/AppData/Local/Programs/Python/Python313/python.exe"
SESSION_LOG="context/session-log.md"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

# Read stdin (hook input JSON) but don't block on it
INPUT=$(cat 2>/dev/null || echo '{}')

# Get recent git changes as context for the debrief
RECENT_CHANGES=$(git log --oneline -10 2>/dev/null || echo "no git history")
CHANGED_FILES=$(git diff --name-only HEAD~3 HEAD 2>/dev/null | head -20 || echo "unknown")

# Build the prompt for the background subagent
PROMPT="You are a session debrief agent for GooseBot. Your job is to:

1. Look at what was done this session based on recent git changes
2. Append a SHORT (3-5 line) structured entry to context/session-log.md
3. Check if any context docs in context/ need updating based on what happened
4. If context docs are stale, update them with the new information
5. Commit any changes with message 'chore(auto): session debrief update'

Recent git log:
$RECENT_CHANGES

Recently changed files:
$CHANGED_FILES

Session log entry format:
## $TIMESTAMP
- **Task:** [what was done]
- **Decisions:** [key decisions made]
- **Open:** [anything left pending]

Rules:
- Keep session log entries SHORT (3-5 lines max)
- Only update context docs if something meaningfully changed (new person, new tool, architecture change)
- Do NOT update context docs for routine work (bug fixes, deployments, email triage)
- Commit silently — no push"

# Run claude in background with --print mode (non-interactive)
# Use sonnet for efficiency
nohup claude --print --model sonnet --dangerously-skip-permissions -p "$PROMPT" \
  > /dev/null 2>&1 &

exit 0
