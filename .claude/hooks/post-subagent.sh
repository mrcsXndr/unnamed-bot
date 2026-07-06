#!/usr/bin/env bash
# SubagentStop hook — runs after the Agent tool returns.
#
# Writes a cheap ZERO-LLM critic envelope (tools/v2/critic.py score) to
# memory/sessions/<id>/critic-<ts>.json and appends a one-line journal note.
# No tokens are spent here — actual credibility grading is deliberate /
# on-demand via the `critic` subagent or the /critic command.
#
# Inputs
#   $1  — task spec file (or "-" if not available)
#   $2  — agent result file
#   stdin — optional JSON {session_id:"...", task:"...", result:"..."}
#
# STRICTLY FAIL-OPEN: always exits 0.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 0
REPO="$PWD"
PY="${PYTHON:-python}"
export PYTHONIOENCODING=utf-8

TASK_FILE="${1:--}"
RESULT_FILE="${2:-}"
SESSION_ID=""

# Try stdin payload if positional args missing
PAYLOAD=""
if ! [ -t 0 ]; then
  PAYLOAD=$(cat || true)
fi
if [ -n "$PAYLOAD" ] && [ -z "$RESULT_FILE" ]; then
  TMP_TASK=$(mktemp)
  TMP_RESULT=$(mktemp)
  TMP_SESSION=$(mktemp)
  "$PY" -c "
import json, sys
d = json.loads(sys.argv[1] or '{}')
open(sys.argv[2], 'w', encoding='utf-8').write(d.get('task',''))
open(sys.argv[3], 'w', encoding='utf-8').write(d.get('result',''))
print(d.get('session_id',''))
" "$PAYLOAD" "$TMP_TASK" "$TMP_RESULT" > "$TMP_SESSION" 2>/dev/null || true
  TASK_FILE="$TMP_TASK"
  RESULT_FILE="$TMP_RESULT"
  SESSION_ID=$(cat "$TMP_SESSION" 2>/dev/null || true)
  rm -f "$TMP_SESSION" 2>/dev/null || true
fi

if [ -z "$SESSION_ID" ] && [ -f "$REPO/.claude/.current_session_id" ]; then
  SESSION_ID=$(cat "$REPO/.claude/.current_session_id" 2>/dev/null || true)
fi
if [ -z "$SESSION_ID" ]; then
  echo "[post-subagent] no session id available; skipping critic envelope" >&2
  exit 0
fi

if [ -z "$RESULT_FILE" ] || [ ! -f "$RESULT_FILE" ]; then
  echo "[post-subagent] no result file; skipping critic envelope" >&2
  exit 0
fi

CRITIC_JSON=$("$PY" "$REPO/tools/v2/critic.py" score "$TASK_FILE" "$RESULT_FILE" 2>/dev/null || echo '{"status":"critic-failed"}')

# Append a single journal entry with the headline summary
SUMMARY=$(printf '%s' "$CRITIC_JSON" | "$PY" -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    n = len(d.get('claims', []))
    s = d.get('overall_score')
    st = d.get('status','?')
    print(f'critic-pass: {n} claims, overall={s}, status={st}')
except Exception as e:
    print(f'critic-pass: parse-error {e!r}')
" 2>/dev/null || echo "critic-pass: (unparseable)")

"$PY" "$REPO/tools/v2/journal.py" append "$SESSION_ID" finding "$SUMMARY" >/dev/null 2>&1 || true

# Also write the full critic JSON to the session dir for the main thread to Read
SESSION_DIR="$REPO/memory/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR" 2>/dev/null || true
TS=$(date -u +%Y%m%dT%H%M%SZ)
printf '%s\n' "$CRITIC_JSON" > "$SESSION_DIR/critic-$TS.json"

exit 0
