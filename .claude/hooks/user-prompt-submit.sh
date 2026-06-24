#!/usr/bin/env bash
# UserPromptSubmit hook (v2)
#
# What it does:
#   1. Parse the Claude Code UserPromptSubmit JSON payload from stdin.
#   2. INBOUND SIZE GUARD - if a single prompt is huge (paste / log dump / convo
#      export), stash the raw blob and redirect attention instead of polluting
#      context inline.
#
# Defensive: ANY error -> exit 0 (fail open - never silently drop a message).

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

# Extract prompt + session id from JSON payload
PROMPT=""
SESSION_ID=""
if [ -n "$PAYLOAD" ]; then
  read -r PROMPT SESSION_ID < <("$PY" -c "
import json, sys
try:
    d = json.loads(sys.argv[1] or '{}')
    p = (d.get('prompt') or '').replace('\n', '\\n')
    s = d.get('session_id') or ''
    print(p, s)
except Exception:
    print('', '')
" "$PAYLOAD" 2>/dev/null || true)
fi

if [ -z "$PROMPT" ]; then
  exit 0
fi

if [ -z "$SESSION_ID" ] && [ -f "$REPO/.claude/.current_session_id" ]; then
  SESSION_ID=$(cat "$REPO/.claude/.current_session_id" 2>/dev/null || true)
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(date -u +%Y%m%d-%H%M%S)
fi

# Restore literal newlines in PROMPT
PROMPT_REAL=$(printf '%b' "$PROMPT")

# --- INBOUND SIZE GUARD ---
# If a single prompt is huge (paste / log dump / convo export), don't let it
# silently pollute context. Stash the raw blob and inject a directive telling
# the assistant to Read or dispatch instead of reasoning over the whole thing
# inline. Threshold: 50K chars (~12K tokens).
PROMPT_SIZE=${#PROMPT_REAL}
SIZE_THRESHOLD=${BOT_V2_SIZE_THRESHOLD:-50000}
if [ "$PROMPT_SIZE" -gt "$SIZE_THRESHOLD" ]; then
  STASH_DIR="$REPO/.claude/stash"
  mkdir -p "$STASH_DIR" 2>/dev/null || true
  TS_NOW=$(date -u +%Y%m%dT%H%M%SZ)
  STASH_FILE="$STASH_DIR/paste_${SESSION_ID}_${TS_NOW}.txt"
  printf '%s' "$PROMPT_REAL" > "$STASH_FILE" 2>/dev/null || true
  EST_TOKENS=$((PROMPT_SIZE / 4))
  HEAD=$(printf '%s' "$PROMPT_REAL" | head -c 1500)
  GUARD_MSG=$(cat <<EOF
[INBOUND-SIZE-GUARD] User's prompt is $PROMPT_SIZE chars (~$EST_TOKENS tokens). Full payload stashed at: $STASH_FILE

Do NOT ingest the entire blob into reasoning context. Choose one:
  1. Read the file with offset/limit for the relevant slice only
  2. Dispatch a one-shot subagent (fresh ctx) to summarise/extract
  3. If the user's actual ask is clear from the head, answer that and ignore the dump

Prompt head (first 1500 chars):
$HEAD
EOF
)
  "$PY" "$REPO/tools/v2/journal.py" append "$SESSION_ID" observation "large-paste guarded: ~$EST_TOKENS tokens stashed to .claude/stash/$(basename "$STASH_FILE")" >/dev/null 2>&1 || true
  ESCAPED=$(printf '%s' "$GUARD_MSG" | "$PY" -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' "$ESCAPED"
fi

# Default: pass through to the main thread (exit 0).
exit 0
