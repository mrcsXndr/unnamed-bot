#!/usr/bin/env bash
# Sync secrets & settings between machines via Google Drive
# Usage: bash tools/sync_settings.sh push|pull|status

set -euo pipefail

DRIVE_DIR="${SYNC_DRIVE_PATH:-}"
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
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
  # Gitignored local overrides. NOTE: TG plugin enablement does NOT live here —
  # it lives in the TRACKED .claude/tg-enable.settings.json (the launcher passes
  # it via --settings; git is its backup). Kept for any future local overrides.
  ".claude/settings.local.json:claude-project-settings.local.json"
)

# How often push actually WRITES (seconds). Self-gate so calling push often
# (e.g. from launch or a supervisor tick) can't spam Drive. Default 6h.
PUSH_MIN_INTERVAL="${BOT_PUSH_MIN_INTERVAL:-21600}"
# Per-repo ts marker so bot clones sharing this $HOME don't share one gate.
PUSH_TS_FILE="$HOME_DIR/.$(basename "$PROJECT_DIR")_secret_backup_ts"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[sync]${NC} $*"; }
warn() { echo -e "${YELLOW}[sync]${NC} $*"; }
err()  { echo -e "${RED}[sync]${NC} $*" >&2; }

check_drive() {
  if [ -z "$DRIVE_DIR" ]; then
    err "SYNC_DRIVE_PATH is not set."
    err "Set it to your Google Drive backup folder, e.g.:"
    err "  export SYNC_DRIVE_PATH=\"/path/to/Google Drive/Backup/bot-secrets\""
    err "Or add it to your .env file: SYNC_DRIVE_PATH=..."
    exit 1
  fi
  if [ ! -d "$DRIVE_DIR" ]; then
    err "Google Drive not mounted or backup dir missing: $DRIVE_DIR"
    err "Create it: mkdir -p \"$DRIVE_DIR\""
    exit 1
  fi
}

do_push() {
  # Self-gate: skip if a push ran within PUSH_MIN_INTERVAL (unless FORCE=1).
  if [ "${FORCE:-0}" != "1" ] && [ -f "$PUSH_TS_FILE" ]; then
    local last now age; last=$(cat "$PUSH_TS_FILE" 2>/dev/null || echo 0); now=$(date +%s)
    age=$(( now - last ))
    if [ "$age" -lt "$PUSH_MIN_INTERVAL" ]; then
      log "push skipped — last backup $(( age / 3600 ))h ago (gate ${PUSH_MIN_INTERVAL}s; use FORCE=1 to override)"
      return 0
    fi
  fi
  log "Pushing settings to Google Drive..."
  local count=0

  # Timeout-wrapped copy: a hung Drive mount must never stall the caller (a
  # supervisor tick may run push synchronously). Skips byte-identical files.
  push_copy() {
    local src="$1" dst="$2" label="$3"
    if [ -f "$dst" ] && cmp -s "$src" "$dst" 2>/dev/null; then
      log "  $label (unchanged)"
      return 0
    fi
    if timeout 15 cp "$src" "$dst" 2>/dev/null; then
      log "  $label"
      return 0
    else
      warn "  $label push TIMED OUT/failed (Drive mount hung?)"
      return 1
    fi
  }

  for f in "${PROJECT_FILES[@]}"; do
    src="$PROJECT_DIR/$f"; dst="$DRIVE_DIR/$f"
    if [ -f "$src" ]; then push_copy "$src" "$dst" "$f" && count=$((count + 1))
    else warn "  skip $f (not found)"; fi
  done
  for entry in "${HOME_FILES[@]}"; do
    IFS=':' read -r home_rel drive_rel <<< "$entry"
    src="$HOME_DIR/$home_rel"; dst="$DRIVE_DIR/$drive_rel"
    if [ -f "$src" ]; then push_copy "$src" "$dst" "~/$home_rel -> $drive_rel" && count=$((count + 1))
    else warn "  skip ~/$home_rel (not found)"; fi
  done
  for entry in "${CLAUDE_PROJECT_FILES[@]}"; do
    IFS=':' read -r proj_rel drive_rel <<< "$entry"
    src="$PROJECT_DIR/$proj_rel"; dst="$DRIVE_DIR/$drive_rel"
    if [ -f "$src" ]; then push_copy "$src" "$dst" "$proj_rel -> $drive_rel" && count=$((count + 1))
    else warn "  skip $proj_rel (not found)"; fi
  done
  # Sync Claude Code memories
  local mem_drive="$DRIVE_DIR/memory"
  mkdir -p "$mem_drive"
  local mem_found=0
  for mem_dir in "$HOME_DIR/.claude/projects/"*/memory/; do
    if [ -d "$mem_dir" ]; then
      for md_file in "$mem_dir"*.md; do
        [ -f "$md_file" ] || continue
        cp "$md_file" "$mem_drive/$(basename "$md_file")"
        log "  memory/$(basename "$md_file")"
        count=$((count + 1)); mem_found=1
      done
    fi
  done
  [ "$mem_found" -eq 0 ] && warn "  skip memory (no .claude/projects/*/memory/ found)"
  date +%s > "$PUSH_TS_FILE" 2>/dev/null || true
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
  # Sync Claude Code memories
  local mem_drive="$DRIVE_DIR/memory"
  if [ -d "$mem_drive" ]; then
    local mem_dst=""
    for mem_dir in "$HOME_DIR/.claude/projects/"*/memory/; do
      if [ -d "$mem_dir" ]; then mem_dst="$mem_dir"; break; fi
    done
    if [ -n "$mem_dst" ]; then
      for md_file in "$mem_drive"/*.md; do
        [ -f "$md_file" ] || continue
        cp "$md_file" "$mem_dst/$(basename "$md_file")"
        log "  memory/$(basename "$md_file") -> $mem_dst"
        count=$((count + 1))
      done
    else
      warn "  skip memory pull (no .claude/projects/*/memory/ found locally)"
    fi
  else
    warn "  skip memory pull ($mem_drive not in backup)"
  fi
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

[ "${2:-}" = "--force" ] && FORCE=1
case "${1:-help}" in
  push)   check_drive; do_push ;;
  pull)   check_drive; do_pull ;;
  status) check_drive; do_status ;;
  *)
    echo "Usage: bash tools/sync_settings.sh <command>"
    echo "Commands: push | pull | status"
    echo ""
    echo "Set SYNC_DRIVE_PATH env var to your Google Drive backup folder"
    echo "Example: export SYNC_DRIVE_PATH=\"/path/to/Google Drive/Backup/bot-secrets\""
    ;;
esac
