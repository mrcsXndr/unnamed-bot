#!/usr/bin/env bash
# install_profile.sh — add a one-word `bot` launch command to your shell.
#
# After this runs, open a NEW terminal and just type:
#     bot
# to start the long-running conversation — no need to remember
# `bash scripts/launch.sh` or where the repo lives.
#
# Idempotent: the command lives in a MANAGED BLOCK between markers, so re-running
# replaces only that block and never touches the rest of your rc file. Writes to
# ~/.bashrc and, if present, ~/.zshrc.
#
# Usage:
#   bash scripts/install_profile.sh
#   bash scripts/install_profile.sh --alias goosey   # extra alias name
#   bash scripts/install_profile.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

ALIAS_NAME=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --alias) ALIAS_NAME="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) shift ;;
  esac
done

# alias name: --alias > BOT_NAME in .env > "bot"; sanitize to a valid shell name
if [ -z "$ALIAS_NAME" ] && [ -f "$REPO/.env" ]; then
  ALIAS_NAME="$(grep -E '^\s*BOT_NAME\s*=' "$REPO/.env" 2>/dev/null | head -1 | sed -E 's/^[^=]*=//; s/^["'\'' ]+//; s/["'\'' ]+$//')"
  case "$ALIAS_NAME" in *YOUR_*_HERE*) ALIAS_NAME="" ;; esac
fi
ALIAS_NAME="$(printf '%s' "$ALIAS_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]//g; s/^[0-9]+//')"
[ -z "$ALIAS_NAME" ] && ALIAS_NAME="bot"

MARKER="# --- bot launcher (managed by install_profile.sh) ---"
END_MARKER="# --- end bot launcher ---"

ALIAS_LINE=""
[ "$ALIAS_NAME" != "bot" ] && ALIAS_LINE="alias ${ALIAS_NAME}=bot"

read -r -d '' BLOCK <<EOF || true
$MARKER
bot() {
  ( cd "$REPO" && bash scripts/launch.sh "\$@" )
}
$ALIAS_LINE
$END_MARKER
EOF

echo ""
echo "  Shell launch command"
echo "  Repo:    $REPO"
if [ "$ALIAS_NAME" != "bot" ]; then echo "  Command: bot  (+ alias: $ALIAS_NAME)"; else echo "  Command: bot"; fi
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "  (dry-run) would install this block into ~/.bashrc (and ~/.zshrc if present):"
  echo ""
  printf '%s\n' "$BLOCK"
  exit 0
fi

install_into() {
  local rc="$1"
  [ -e "$rc" ] || touch "$rc"
  # strip any previous managed block, then append the fresh one
  if grep -qF "$MARKER" "$rc" 2>/dev/null; then
    sed -i.bak "/$(printf '%s' "$MARKER" | sed 's/[.[\*^$/]/\\&/g')/,/$(printf '%s' "$END_MARKER" | sed 's/[.[\*^$/]/\\&/g')/d" "$rc" && rm -f "$rc.bak"
  fi
  printf '\n%s\n' "$BLOCK" >> "$rc"
  echo "  installed into: $rc"
}

install_into "$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && install_into "$HOME/.zshrc"

echo ""
echo "  Open a NEW terminal, then type:  bot"
echo ""
