#!/usr/bin/env bash
# UserPromptSubmit hook (v2)
#
# What this hook does:
#   1. Parse the Claude Code UserPromptSubmit JSON payload from stdin.
#   2. TG SLASH-COMMAND INTERCEPT — /status /journal /timeline /compact /tasks
#      /costs /update /help are handled by tools/v2/tg_commands.py and blocked
#      from the main thread (exit 2). The reply goes straight back to Telegram.
#   3. INBOUND SIZE GUARD — stash huge pastes and redirect Director attention
#      instead of polluting context inline.
#
# Defensive: ANY error -> exit 0 (fail open — never silently drop a message).

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 0
REPO="$PWD"

PY="${PYTHON:-python}"
export PYTHONIOENCODING=utf-8

PAYLOAD=""
if ! [ -t 0 ]; then
  PAYLOAD=$(cat || true)
fi

# Extract prompt + session id (+ inbound reply-to message id) from the payload.
PROMPT=""
SESSION_ID=""
REPLY_TO=""
if [ -n "$PAYLOAD" ]; then
  # ONE python call, reading the payload from STDIN — NEVER as an argv arg. A
  # prompt >~32K chars passed as argv hits "Argument list too long" on Windows;
  # the parse then silently fails and PROMPT="" so the inbound size guard could
  # never fire (it fires at 50K > the argv limit). Reading stdin removes the cap.
  # We also keep the prompt RAW here — the old code re-escaped newlines and ran
  # `printf '%b'`, which mangled backslashes in Windows paths
  # (C:\temp\new -> C:<tab>emp<lf>ew) and injected CR. Output shape:
  #   line1 = session_id, line2 = reply_to msg id, line3+ = raw prompt.
  PARSED=$(printf '%s' "$PAYLOAD" | "$PY" -c '
import json, re, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    d = {}
p = d.get("prompt") or ""
s = d.get("session_id") or ""
m = re.search(r"message_id=\"(\d+)\"", p)
sys.stdout.write((s or "") + "\n")
sys.stdout.write((m.group(1) if m else "") + "\n")
sys.stdout.write(p)
' 2>/dev/null || true)
  SESSION_ID=$(printf '%s' "$PARSED" | sed -n '1p')
  REPLY_TO=$(printf '%s' "$PARSED" | sed -n '2p')
  PROMPT=$(printf '%s' "$PARSED" | sed -n '3,$p')
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

# Prompt is kept RAW (see the payload-parse note above) — no %b re-escaping,
# so Windows-path backslashes and other literals survive intact.
PROMPT_REAL="$PROMPT"

# --- TG SLASH-COMMAND INTERCEPT ---
# If the prompt is a TG-style slash command, handle it directly and block the
# main thread. tg_commands.py exit codes: 0=handled, 1=not-a-cmd,
# 2=handled-with-error.
# REPLY_TO (inbound TG message_id for threading) was extracted in the parse above.

FIRST_CHAR="${PROMPT_REAL:0:1}"
if [ "$FIRST_CHAR" = "/" ]; then
  # Prompt goes via STDIN ('-'): on Windows/Git Bash, MSYS converts a
  # leading-slash argv ("/help") into a Windows path, which would break the
  # intercept. stdin is never path-converted.
  CMD_RC=$(printf '%s' "$PROMPT_REAL" | "$PY" "$REPO/tools/v2/tg_commands.py" - "$REPLY_TO" >/dev/null 2>&1; echo $?)
  if [ "$CMD_RC" = "0" ] || [ "$CMD_RC" = "2" ]; then
    "$PY" "$REPO/tools/v2/journal.py" append "$SESSION_ID" action "tg-command handled: ${PROMPT_REAL:0:80}" >/dev/null 2>&1 || true
    echo "[tg_commands] handled $PROMPT_REAL — reply sent to TG, blocking main thread" >&2
    exit 2
  fi
fi

# --- INBOUND SIZE GUARD ---
# If a single prompt is huge (paste / log dump / convo export), don't let it
# silently pollute Director context. Stash the raw blob and inject a strong
# directive telling the Director to Read or dispatch instead of reasoning over
# the whole thing inline. Threshold: 50K chars (~12K tokens).
PROMPT_SIZE=${#PROMPT_REAL}
SIZE_THRESHOLD=${BOT_SIZE_THRESHOLD:-50000}
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

# Default: pass through to main thread (exit 0).
exit 0
