#!/usr/bin/env bash
# Sync secrets & settings between machines via Google Drive
# Usage: bash tools/sync_settings.sh push|pull|status

set -euo pipefail

DRIVE_DIR="${SYNC_DRIVE_PATH:-/g/My Drive/Backup/bot-secrets}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME"

# Files to sync
declare -a PROJECT_FILES=(
  "credentials.json"
  "token.json"
  ".env"
)

declare -a HOME_FILES=(
  ".bashrc:bashrc"
  ".bash_profile:bash_profile"
  ".claude/settings.json:claude-user-settings.json"
  "Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1:ps_profile.ps1"
)

declare -a CLAUDE_PROJECT_FILES=(
  ".claude/settings.json:claude-project-settings.json"
)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[sync]${NC} $*"; }
warn() { echo -e "${YELLOW}[sync]${NC} $*"; }
err()  { echo -e "${RED}[sync]${NC} $*" >&2; }

check_drive() {
  if [ ! -d "$DRIVE_DIR" ]; then
    err "Google Drive not mounted or backup dir missing: $DRIVE_DIR"
    err "Create it: mkdir -p \"$DRIVE_DIR\""
    exit 1
  fi
}

do_push() {
  log "Pushing settings to Google Drive..."
  local count=0
  for f in "${PROJECT_FILES[@]}"; do
    src="$PROJECT_DIR/$f"; dst="$DRIVE_DIR/$f"
    if [ -f "$src" ]; then cp "$src" "$dst"; log "  $f"; count=$((count + 1))
    else warn "  skip $f (not found)"; fi
  done
  for entry in "${HOME_FILES[@]}"; do
    IFS=':' read -r home_rel drive_rel <<< "$entry"
    src="$HOME_DIR/$home_rel"; dst="$DRIVE_DIR/$drive_rel"
    if [ -f "$src" ]; then cp "$src" "$dst"; log "  ~/$home_rel -> $drive_rel"; count=$((count + 1))
    else warn "  skip ~/$home_rel (not found)"; fi
  done
  for entry in "${CLAUDE_PROJECT_FILES[@]}"; do
    IFS=':' read -r proj_rel drive_rel <<< "$entry"
    src="$PROJECT_DIR/$proj_rel"; dst="$DRIVE_DIR/$drive_rel"
    if [ -f "$src" ]; then cp "$src" "$dst"; log "  $proj_rel -> $drive_rel"; count=$((count + 1))
    else warn "  skip $proj_rel (not found)"; fi
  done
  log "Pushed $count items to Drive."
}

do_pull() {
  log "Pulling settings from Google Drive..."
  local count=0
  for f in "${PROJECT_FILES[@]}"; do
    src="$DRIVE_DIR/$f"; dst="$PROJECT_DIR/$f"
    if [ -f "$src" ]; then cp "$src" "$dst"; log "  $f"; count=$((count + 1))
    else warn "  skip $f (not in backup)"; fi
  done
  for entry in "${HOME_FILES[@]}"; do
    IFS=':' read -r home_rel drive_rel <<< "$entry"
    src="$DRIVE_DIR/$drive_rel"; dst="$HOME_DIR/$home_rel"
    if [ -f "$src" ]; then mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; log "  $drive_rel -> ~/$home_rel"; count=$((count + 1))
    else warn "  skip $drive_rel (not in backup)"; fi
  done
  for entry in "${CLAUDE_PROJECT_FILES[@]}"; do
    IFS=':' read -r proj_rel drive_rel <<< "$entry"
    src="$DRIVE_DIR/$drive_rel"; dst="$PROJECT_DIR/$proj_rel"
    if [ -f "$src" ]; then mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; log "  $drive_rel -> $proj_rel"; count=$((count + 1))
    else warn "  skip $drive_rel (not in backup)"; fi
  done
  log "Pulled $count items from Drive."
}

do_status() {
  log "Comparing local vs Drive backup..."
  local diffs=0
  for f in "${PROJECT_FILES[@]}"; do
    local_f="$PROJECT_DIR/$f"; drive_f="$DRIVE_DIR/$f"
    if [ ! -f "$local_f" ] && [ ! -f "$drive_f" ]; then continue
    elif [ ! -f "$local_f" ]; then warn "  $f: only in Drive"; diffs=$((diffs + 1))
    elif [ ! -f "$drive_f" ]; then warn "  $f: only local"; diffs=$((diffs + 1))
    elif ! diff -q "$local_f" "$drive_f" > /dev/null 2>&1; then warn "  $f: DIFFERS"; diffs=$((diffs + 1))
    else log "  $f: in sync"; fi
  done
  if [ "$diffs" -eq 0 ]; then log "Everything in sync."
  else warn "$diffs file(s) out of sync."; fi
}

case "${1:-help}" in
  push)   check_drive; do_push ;;
  pull)   check_drive; do_pull ;;
  status) check_drive; do_status ;;
  *)
    echo "Usage: bash tools/sync_settings.sh <command>"
    echo "Commands: push | pull | status"
    echo ""
    echo "Set SYNC_DRIVE_PATH env var to change backup location"
    echo "Default: /g/My Drive/Backup/bot-secrets"
    ;;
esac
