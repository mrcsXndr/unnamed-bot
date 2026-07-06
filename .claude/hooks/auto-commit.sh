#!/usr/bin/env bash
# Auto-commit uncommitted changes on session stop.
#
# OPT-IN: does nothing unless FEATURE_AUTO_COMMIT=1 in .env (set by the setup
# wizard, or edit .env by hand). Commits locally only — never pushes.
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR" || exit 0

grep -qsE '^FEATURE_AUTO_COMMIT=1' .env 2>/dev/null || exit 0

if [ -z "$(git status --porcelain)" ]; then
  exit 0
fi
git add -A
git commit -m "chore(auto): session checkpoint $(date +%Y-%m-%d' '%H:%M)" --no-verify 2>/dev/null || true

# Optional: push secrets/settings snapshot to a sync folder (separate opt-in).
if grep -qsE '^FEATURE_SECRETS_BACKUP=1' .env 2>/dev/null; then
  bash "$PROJECT_DIR/tools/infra/sync_settings.sh" push 2>/dev/null || true
fi
exit 0
