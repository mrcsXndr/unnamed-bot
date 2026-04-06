#!/usr/bin/env bash
# Auto-commit uncommitted changes on session stop
cd "$(dirname "$0")/../.." || exit 0
if [ -z "$(git status --porcelain)" ]; then
  exit 0
fi
git add -A
git commit -m "chore(auto): session checkpoint $(date +%Y-%m-%d' '%H:%M)" --no-verify 2>/dev/null || true
