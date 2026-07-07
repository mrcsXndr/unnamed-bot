#!/usr/bin/env bash
# launch.sh — one-command startup for the bot on macOS / Linux (and Git Bash).
#
# Run: bash scripts/launch.sh
#   launch.sh              # interactive Continue/Fresh menu
#   launch.sh --continue   # non-interactive: resume last session
#   launch.sh --fresh      # non-interactive: start a fresh session
#
# What it does:
#   1. Optionally pulls latest secrets/settings + repo (opt-in via .env flags).
#   2. Honors the one-shot .claude/.bot_fresh_restart marker (forces FRESH).
#   3. Asks whether to CONTINUE the last session or start a NEW one.
#   4. Launches Claude Code — with the Telegram channel plugin attached when a
#      real TELEGRAM_BOT_TOKEN is configured in .env.
#
# NOTE: run only ONE instance with the Telegram channel at a time. The TG Bot
# API allows a single getUpdates long-poller per token; a second instance
# steals the slot and the first silently stops receiving messages.
#
# The supervisor / watchdog / auto-restart layer is Windows-only (scheduled
# tasks). On macOS/Linux this launcher + hooks are fully functional; see
# docs/SETUP.md for a cron/systemd sketch if you want auto-restart there.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

env_value() { grep -sE "^$1=" .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"; }
feature_on() { [ "$(env_value "$1")" = "1" ]; }

MODE=""
case "${1:-}" in
  --continue) MODE="continue"; shift ;;
  --fresh)    MODE="fresh"; shift ;;
esac

# --- optional: pull secrets/settings + repo (opt-in) -------------------------
if feature_on FEATURE_SECRETS_BACKUP && [ -f tools/infra/sync_settings.sh ]; then
  echo "Syncing settings from backup folder..."
  bash tools/infra/sync_settings.sh pull 2>/dev/null || true
fi
if feature_on FEATURE_MEMORY_SYNC; then
  git pull --rebase --autostash >/dev/null 2>&1 || true
fi

# --- fresh-restart marker (one-shot; dropped by auto-restart flows) ----------
if [ -f .claude/.bot_fresh_restart ]; then
  rm -f .claude/.bot_fresh_restart 2>/dev/null || true
  MODE="fresh"
  echo "  auto-restart marker -> FRESH session (journal/timeline/recall restore context)."
fi

# --- continue-or-fresh -------------------------------------------------------
if [ -z "$MODE" ]; then
  echo ""
  echo "  [1] Continue last session (default — long-running)"
  echo "  [2] Start fresh session"
  echo ""
  read -r -p "  Choice (1/2, blank=1): " choice
  if [ "${choice:-1}" = "2" ]; then MODE="fresh"; else MODE="continue"; fi
fi

# --- Telegram channel: only when a real token is configured ------------------
TOKEN="$(env_value TELEGRAM_BOT_TOKEN)"
CHANNELS=()
if [ -n "$TOKEN" ] && ! printf '%s' "$TOKEN" | grep -q 'YOUR_.*_HERE'; then
  CHANNELS=(--channels "plugin:telegram@claude-plugins-official")
  export BOT_HAS_TG=1
else
  export BOT_HAS_TG=0
fi

if [ "$MODE" = "fresh" ]; then
  echo "  Starting fresh — journal will be created by the session-start hook."
  exec claude --dangerously-skip-permissions ${CHANNELS[@]+"${CHANNELS[@]}"} "$@"
else
  echo "  Resuming — journal/timeline restore prior context."
  exec claude --dangerously-skip-permissions --continue ${CHANNELS[@]+"${CHANNELS[@]}"} "$@"
fi
