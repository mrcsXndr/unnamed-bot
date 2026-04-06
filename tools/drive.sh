#!/usr/bin/env bash
# Google Drive CLI wrapper
# Usage:
#   drive.sh search "query"           # Search files
#   drive.sh recent [count]           # Recent files
#   drive.sh download <file_id> <path> # Download file
#   drive.sh list <folder_id>         # List folder contents

set -euo pipefail

PYTHON="/c/Users/xndr/AppData/Local/Programs/Python/Python313/python.exe"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/google_workspace.py"
export PYTHONIOENCODING=utf-8

CMD="${1:?Usage: drive.sh search|recent|download|list}"

case "$CMD" in
  search)
    QUERY="${2:?Usage: drive.sh search \"query\"}"
    "$PYTHON" "$SCRIPT" drive-search "$QUERY"
    ;;
  recent)
    COUNT="${2:-10}"
    "$PYTHON" "$SCRIPT" drive-recent "$COUNT"
    ;;
  download)
    FILE_ID="${2:?File ID required}"
    OUTPUT="${3:?Output path required}"
    "$PYTHON" "$SCRIPT" drive-download "$FILE_ID" "$OUTPUT"
    ;;
  list)
    FOLDER_ID="${2:?Folder ID required}"
    "$PYTHON" "$SCRIPT" drive-list "$FOLDER_ID"
    ;;
  *)
    echo "Usage: drive.sh {search|recent|download|list}"
    ;;
esac
