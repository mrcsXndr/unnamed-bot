#!/usr/bin/env bash
# smoke_test.sh — self-verify the bot harness WITHOUT booting Claude Code.
#
# Run it after setup (the wizard offers it) or any time something feels off:
#   bash scripts/smoke_test.sh
# On Windows, run it from Git Bash (installed with git), or use
#   pwsh -File scripts\smoke_test.ps1
#
# What it checks:
#   1. Python >= 3.10 resolves
#   2. .claude/settings.json is valid JSON
#   3. every agent definition has name/description/model frontmatter
#   4. every hook exists and parses (bash -n)
#   5. the v2 tools (journal/timeline/recall/commitments/critic/tg_send) run
#   6. journal create/append/read round-trips
#   7. timeline builds from the journal
#   8. the recall index builds and finds a canary entry
#   9. critic returns a valid JSON envelope
#
# It writes only to a throwaway memory/sessions/smoke-* dir and cleans up
# after itself. Exit: 0 all pass, 1 otherwise.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$PWD"

PY="${PYTHON:-}"
[ -n "$PY" ] || PY="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"
if [ -z "$PY" ]; then
  echo "FATAL: no python found on PATH (run scripts/install_deps.sh)" >&2
  exit 1
fi
export PYTHONIOENCODING=utf-8

PASS=0
FAIL=0
FAILED_CHECKS=()

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1" >&2; FAIL=$((FAIL+1)); FAILED_CHECKS+=("$1"); }

SES="smoke-$(date +%Y%m%d-%H%M%S)"
cleanup() {
  rm -rf "$REPO/memory/sessions/$SES" 2>/dev/null || true
  # re-index so the throwaway session doesn't linger in recall
  "$PY" "$REPO/tools/v2/recall.py" index --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== Bot harness smoke test ==="

echo ""
echo "[1/9] Python version..."
if "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
  ok "python >= 3.10 ($("$PY" --version 2>&1))"
else
  fail "python >= 3.10 required (found: $("$PY" --version 2>&1))"
fi

echo ""
echo "[2/9] settings.json valid..."
if "$PY" -m json.tool "$REPO/.claude/settings.json" >/dev/null 2>&1; then
  ok ".claude/settings.json parses as JSON"
else
  fail ".claude/settings.json is not valid JSON"
fi

echo ""
echo "[3/9] Agent frontmatter..."
for f in "$REPO/.claude/agents/"*.md; do
  [ -e "$f" ] || { fail "no agent definitions in .claude/agents/"; break; }
  name=$(basename "$f" .md)
  if grep -q "^name:" "$f" && grep -q "^description:" "$f" && grep -q "^model:" "$f"; then
    ok "agent $name has name + description + model"
  else
    fail "agent $name missing frontmatter (needs name/description/model)"
  fi
done

echo ""
echo "[4/9] Hooks present + parse..."
for h in session-start-v2.sh user-prompt-submit.sh post-subagent.sh block-dialogs.sh; do
  if [ ! -f "$REPO/.claude/hooks/$h" ]; then
    fail "hook $h missing"
  elif bash -n "$REPO/.claude/hooks/$h" 2>/dev/null; then
    ok "hook $h present + parses"
  else
    fail "hook $h has a bash syntax error"
  fi
done

echo ""
echo "[5/9] Core tools runnable..."
for tool in v2/journal.py v2/timeline.py v2/recall.py v2/commitments.py v2/critic.py tg/tg_send.py; do
  if "$PY" "$REPO/tools/$tool" --help >/dev/null 2>&1 \
     || "$PY" "$REPO/tools/$tool" 2>&1 | grep -qiE 'usage'; then
    ok "tools/$tool runnable"
  else
    fail "tools/$tool not runnable"
  fi
done

echo ""
echo "[6/9] Journal round-trip..."
CANARY="smoke-canary-$(date +%s)"
if "$PY" "$REPO/tools/v2/journal.py" new "$SES" >/dev/null 2>&1; then ok "journal new"; else fail "journal new"; fi
if "$PY" "$REPO/tools/v2/journal.py" append "$SES" finding "$CANARY" >/dev/null 2>&1; then ok "journal append"; else fail "journal append"; fi
if "$PY" "$REPO/tools/v2/journal.py" read "$SES" 2>/dev/null | grep -q "$CANARY"; then
  ok "journal read returns the appended entry"
else
  fail "journal read missing the appended entry"
fi

echo ""
echo "[7/9] Timeline build..."
if "$PY" "$REPO/tools/v2/timeline.py" build "$SES" >/dev/null 2>&1; then ok "timeline build"; else fail "timeline build"; fi
if "$PY" "$REPO/tools/v2/timeline.py" read "$SES" >/dev/null 2>&1; then ok "timeline read"; else fail "timeline read"; fi

echo ""
echo "[8/9] Recall index + search..."
if "$PY" "$REPO/tools/v2/recall.py" index --force >/dev/null 2>&1; then ok "recall index"; else fail "recall index"; fi
if "$PY" "$REPO/tools/v2/recall.py" search "$CANARY" 2>/dev/null | grep -q "$CANARY"; then
  ok "recall search finds the canary entry"
else
  fail "recall search did not find the canary entry"
fi

echo ""
echo "[9/9] Critic envelope..."
TASK_TMP="$(mktemp)"
RESULT_TMP="$(mktemp)"
echo "example task" > "$TASK_TMP"
echo "example result" > "$RESULT_TMP"
if "$PY" "$REPO/tools/v2/critic.py" score "$TASK_TMP" "$RESULT_TMP" 2>/dev/null \
   | "$PY" -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'claims' in d and 'status' in d" 2>/dev/null; then
  ok "critic.py returns a valid envelope JSON"
else
  fail "critic.py invalid output"
fi
rm -f "$TASK_TMP" "$RESULT_TMP"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failed checks:" >&2
  for c in "${FAILED_CHECKS[@]}"; do echo "  - $c" >&2; done
  exit 1
fi
exit 0
