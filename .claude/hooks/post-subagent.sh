#!/usr/bin/env bash
# post-subagent hook (v2) - runs after a subagent (Agent tool) returns.
#
# Wired as a SubagentStop hook in .claude/settings.json. It records a cheap,
# zero-LLM note in the session journal that a subagent returned, so the thread
# of dispatched work is captured in working memory without spending tokens.
#
# For an actual credibility grade of a subagent's output, dispatch a `critic`
# subagent deliberately (Agent tool, subagent_type="critic") - this hook does
# NOT auto-grade (that was found to be pure cost with no payoff).
#
# stdin: optional JSON {session_id:"...", ...} from the SubagentStop event.
# STRICTLY FAIL-OPEN: any error -> exit 0. Never blocks.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 0
REPO="$PWD"
PY="${PYTHON:-${BOT_PYTHON:-}}"
if [ -z "$PY" ]; then
  PY="$(command -v python || command -v python3 || echo python)"
fi
export PYTHONIOENCODING=utf-8

PAYLOAD=""
if ! [ -t 0 ]; then
  PAYLOAD=$(cat || true)
fi

SESSION_ID=""
if [ -n "$PAYLOAD" ]; then
  SESSION_ID=$("$PY" -c "import json,sys; d=json.loads(sys.argv[1] or '{}'); print(d.get('session_id') or '')" "$PAYLOAD" 2>/dev/null || true)
fi
if [ -z "$SESSION_ID" ] && [ -f "$REPO/.claude/.current_session_id" ]; then
  SESSION_ID=$(cat "$REPO/.claude/.current_session_id" 2>/dev/null || true)
fi
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

TS=$(date -u +%H:%M:%S)
"$PY" "$REPO/tools/v2/journal.py" append "$SESSION_ID" action "subagent returned (post-subagent hook @ $TS) - dispatch a /critic pass before acting on consequential claims" >/dev/null 2>&1 || true

exit 0
