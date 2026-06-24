#!/usr/bin/env bash
# SessionStart hook (v2)
# - Injects last-session context + git log
# - Ensures memory/sessions/<session_id>/journal.md exists, refreshes the
#   cross-session recall index, and loads journal + timeline into the SYSTEM
#   prompt (NOT chat history) via additionalContext.
# STRICTLY FAIL-OPEN: every step is guarded; the hook always exits 0.

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 0
REPO="$PWD"

# Resolve a python interpreter from PATH (override with $PYTHON or $BOT_PYTHON).
PY="${PYTHON:-${BOT_PYTHON:-}}"
if [ -z "$PY" ]; then
  PY="$(command -v python || command -v python3 || echo python)"
fi
export PYTHONIOENCODING=utf-8

# Invalidate statusline cost cache so it recalculates this session
rm -f "$HOME/.claude/api_cost_cache.json" 2>/dev/null

# Optional: pull latest settings from a sync folder on session start
if [ -n "${BOT_SECRETS_DIR:-${SYNC_DRIVE_PATH:-}}" ]; then
  bash "$REPO/tools/sync_settings.sh" pull 2>/dev/null || true
fi

# --- Cross-session recall index ------------------------------------------
# Refresh the FTS5 recall index so the assistant can do zero-LLM cross-session
# recall this session. Incremental + mtime-gated (~ms). FAIL-OPEN.
( "$PY" "$REPO/tools/v2/recall.py" index >/dev/null 2>&1 ) || true

# Read session id from Claude Code stdin payload (JSON: {"session_id":"..."})
PAYLOAD=""
if ! [ -t 0 ]; then
  PAYLOAD=$(cat || true)
fi
SESSION_ID=""
if [ -n "$PAYLOAD" ]; then
  SESSION_ID=$("$PY" -c "import json,sys; d=json.loads(sys.argv[1] or '{}'); print(d.get('session_id') or '')" "$PAYLOAD" 2>/dev/null || true)
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(date -u +%Y%m%d-%H%M%S)
fi

# Create journal (idempotent)
"$PY" "$REPO/tools/v2/journal.py" new "$SESSION_ID" >/dev/null 2>&1 || true

JOURNAL_PATH="$REPO/memory/sessions/$SESSION_ID/journal.md"
TIMELINE_PATH="$REPO/memory/sessions/$SESSION_ID/timeline.md"

# --- Last-session context ------------------------------------------------
# Prefer the most recent non-stub timeline.md (distilled narrative), else the
# tail of the most recent journal.md with real entries, else omit. FAIL-OPEN.
LAST_SESSION=$("$PY" - "$REPO" <<'PYEOF' 2>/dev/null || true
import sys
from pathlib import Path

repo = Path(sys.argv[1])
sessions = repo / "memory" / "sessions"
PLACEHOLDERS = ("_(none yet)_", "_(none recorded)_")

def newest_first(glob):
    try:
        files = [p for p in sessions.glob(glob) if p.is_file()]
    except OSError:
        return []
    return sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)

def timeline_payload(p):
    try:
        txt = p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    body = txt
    if body.startswith("---"):
        end = body.find("\n---", 3)
        if end != -1:
            body = body[end + 4:]
    has_content = any(
        ln.strip() and ln.strip() not in PLACEHOLDERS and not ln.lstrip().startswith("#")
        and not ln.strip().startswith(">")
        for ln in body.splitlines()
    )
    if not has_content:
        return None
    return body.strip()[:4000]

def journal_payload(p):
    try:
        lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None
    import re
    entry = re.compile(r"^- \[\d{2}:\d{2}:\d{2}\] (.+)$")
    bullets = [ln for ln in lines if entry.match(ln.strip()) and entry.match(ln.strip()).group(1).strip() not in PLACEHOLDERS]
    if not bullets:
        return None
    return "\n".join(bullets[-15:])[:4000]

for p in newest_first("*/timeline.md"):
    pl = timeline_payload(p)
    if pl:
        print(f"(from {p.parent.name}/timeline.md)\n{pl}")
        sys.exit(0)

for p in newest_first("*/journal.md"):
    pl = journal_payload(p)
    if pl:
        print(f"(recent journal entries - {p.parent.name})\n{pl}")
        sys.exit(0)
PYEOF
)
GIT_LOG=$(git log --oneline -5 2>/dev/null || echo "")

JOURNAL_BODY=""
if [ -f "$JOURNAL_PATH" ]; then
  # Cap journal load (~20K chars / ~5K tokens) so a long session's journal
  # doesn't bloat startup context. Full journal is always on disk if needed.
  JOURNAL_BODY=$(tail -c "${BOT_V2_JOURNAL_HEAD_BYTES:-20000}" "$JOURNAL_PATH" 2>/dev/null || true)
fi
TIMELINE_BODY=""
if [ -f "$TIMELINE_PATH" ]; then
  TIMELINE_BODY=$(cat "$TIMELINE_PATH")
fi

# --- Sanitize external-derived memory before injection (block-on-poison) ---
# journal / timeline / last-session can contain pasted content = a prompt-
# injection persistence vector. Pass each chunk through tools/v2/sanitize_chunk.py
# (thin gate over tools/sanitize.py): HIGH/CRITICAL risk -> [BLOCKED ...] marker;
# otherwise the cleaned chunk is injected. FAIL-OPEN: raw chunk if sanitize fails.
sanitize_chunk() {
  "$PY" "$REPO/tools/v2/sanitize_chunk.py" "$1" 2>/dev/null || cat
}
if [ -n "$LAST_SESSION" ]; then
  LAST_SESSION=$(printf '%s' "$LAST_SESSION" | sanitize_chunk "last-session" || printf '%s' "$LAST_SESSION")
fi
if [ -n "$JOURNAL_BODY" ]; then
  JOURNAL_BODY=$(printf '%s' "$JOURNAL_BODY" | sanitize_chunk "$JOURNAL_PATH" || printf '%s' "$JOURNAL_BODY")
fi
if [ -n "$TIMELINE_BODY" ]; then
  TIMELINE_BODY=$(printf '%s' "$TIMELINE_BODY" | sanitize_chunk "$TIMELINE_PATH" || printf '%s' "$TIMELINE_BODY")
fi

# --- Memory budget header ------------------------------------------------
# Frozen-snapshot usage header so the assistant SEES how full the durable index
# (MEMORY.md) and this session's journal are, and self-consolidates before bloat.
MEMORY_FILE="$REPO/memory/MEMORY.md"
MEMORY_BUDGET=20000
JOURNAL_BUDGET="${BOT_V2_JOURNAL_HEAD_BYTES:-20000}"
BUDGET_HEADER=$("$PY" - "$MEMORY_FILE" "$MEMORY_BUDGET" "$JOURNAL_PATH" "$JOURNAL_BUDGET" <<'PYEOF' 2>/dev/null || true
import os, sys
def line(label, path, budget):
    try:
        n = os.path.getsize(path)
    except OSError:
        return None
    pct = round(100 * n / budget) if budget else 0
    flag = " OVER-BUDGET - consolidate" if n > budget else ""
    return f"[{label}: {pct}% - {n:,}/{budget:,} chars{flag}]"
out = []
for label, path, budget in (
    ("memory", sys.argv[1], int(sys.argv[2])),
    ("journal", sys.argv[3], int(sys.argv[4])),
):
    l = line(label, path, budget)
    if l:
        out.append(l)
print("\n".join(out))
PYEOF
)

CONTEXT=""
if [ -n "$LAST_SESSION" ]; then
  CONTEXT="Last session:\n$LAST_SESSION"
fi
if [ -n "$GIT_LOG" ]; then
  CONTEXT="$CONTEXT\n\nRecent commits:\n$GIT_LOG"
fi
CONTEXT="$CONTEXT\n\n## v2 Context Channels\nSession ID: $SESSION_ID\nJournal: $JOURNAL_PATH\nTimeline: $TIMELINE_PATH"
if [ -n "$BUDGET_HEADER" ]; then
  CONTEXT="$CONTEXT\n\n### Memory budget (frozen snapshot at session start)\n$BUDGET_HEADER"
fi
CONTEXT="$CONTEXT\n\nCross-session recall: run \`python tools/v2/recall.py search \"<query>\"\` for zero-LLM FTS5 recall across ALL past session journals."
if [ -n "$JOURNAL_BODY" ]; then
  CONTEXT="$CONTEXT\n\n### Journal (working memory)\n$JOURNAL_BODY"
fi
if [ -n "$TIMELINE_BODY" ]; then
  CONTEXT="$CONTEXT\n\n### Timeline (distilled narrative)\n$TIMELINE_BODY"
fi

if [ -n "$CONTEXT" ]; then
  ESCAPED=$(printf '%s' "$CONTEXT" | "$PY" -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"
fi

# Stash session id for sibling hooks (UserPromptSubmit etc.)
echo "$SESSION_ID" > "$REPO/.claude/.current_session_id" 2>/dev/null || true

exit 0
