#!/usr/bin/env bash
# Google Sheets CLI wrapper (for TDL access)
# Usage:
#   sheets.sh read <sheet_id> <range>        # Read cells
#   sheets.sh update <sheet_id> <range> <values>  # Update cells
#   sheets.sh append <sheet_id> <range> <values>  # Append row

set -euo pipefail

PYTHON="${PYTHON:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo python)}"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/google_workspace.py"
export PYTHONIOENCODING=utf-8

CMD="${1:?Usage: sheets.sh read|update|append <sheet_id> <range> [values]}"
SHEET_ID="${2:?Sheet ID required}"
RANGE="${3:?Range required (e.g., TDL!A1:F50)}"

case "$CMD" in
  read)
    "$PYTHON" "$SCRIPT" sheets-read "$SHEET_ID" "$RANGE"
    ;;
  update)
    VALUES="${4:?Values required as JSON array}"
    "$PYTHON" "$SCRIPT" sheets-update "$SHEET_ID" "$RANGE" "$VALUES"
    ;;
  append)
    VALUES="${4:?Values required as JSON array}"
    "$PYTHON" "$SCRIPT" sheets-append "$SHEET_ID" "$RANGE" "$VALUES"
    ;;
  *)
    echo "Usage: sheets.sh {read|update|append} <sheet_id> <range> [values]"
    ;;
esac
