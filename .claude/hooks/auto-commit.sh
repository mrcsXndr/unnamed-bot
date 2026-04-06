#!/usr/bin/env bash
# Auto-commit uncommitted changes on session stop
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR" || exit 0
if [ -z "$(git status --porcelain)" ]; then
  exit 0
fi
git add -A
git commit -m "chore(auto): session checkpoint $(date +%Y-%m-%d' '%H:%M)" --no-verify 2>/dev/null || true

# Auto-sync: push settings to Google Drive on session stop
if [ -n "${SYNC_DRIVE_PATH:-}" ] && [ -d "${SYNC_DRIVE_PATH}" ]; then
  bash "$PROJECT_DIR/tools/sync_settings.sh" push 2>/dev/null || true
fi
