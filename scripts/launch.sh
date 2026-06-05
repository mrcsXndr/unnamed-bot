#!/usr/bin/env bash
# launch.sh — one-command startup for the bot on macOS / Linux.
#
# Run: bash scripts/launch.sh
# (or wire up a `mybot` shell function — see README "One-line launcher".)
#
# What it does:
#   1. Clones the repo from the public URL if it isn't there yet.
#   2. Optionally pulls your latest secrets/settings from a sync folder.
#   3. Asks whether to CONTINUE the last session or start a NEW one.
#   4. Launches Claude Code with the Telegram channel plugin attached.
#
# Note: the Windows launcher (launch.ps1) carries two extra fixes for the
# Telegram plugin (an absolute bun path and an LF-only .env write). *nix does
# not need either — bun resolves from PATH normally and shell tools write LF by
# default — so there's nothing to patch here.

set -euo pipefail

# --- 1. Repo location: clone if missing -------------------------------------
REPO="$HOME/Code/my-bot"
if [ ! -d "$REPO" ]; then
    echo "Cloning bot into $REPO ..."
    git clone https://github.com/mrcsXndr/unnamed-bot.git "$REPO"
fi
cd "$REPO"

# --- 2. Optional: pull settings from a sync folder --------------------------
# If you keep secrets/settings in a cloud/USB folder (see README "Multi-machine
# sync"), set SYNC_DRIVE_PATH and this pulls the latest copy on the way in.
if [ -n "${SYNC_DRIVE_PATH:-}" ] && [ -f "$REPO/tools/sync_settings.sh" ]; then
    echo "Pulling latest settings from sync folder..."
    bash "$REPO/tools/sync_settings.sh" pull 2>/dev/null || true
fi

# --- 3. Continue-or-new prompt ----------------------------------------------
echo ""
echo "  [1] Continue last session"
echo "  [2] Start fresh session"
echo ""
read -r -p "Choose: " choice

# --- 4. Launch with the Telegram channel plugin -----------------------------
channels=(--channels "plugin:telegram@claude-plugins-official")

if [ "$choice" = "2" ]; then
    claude --dangerously-skip-permissions "${channels[@]}" "$@"
else
    claude --dangerously-skip-permissions --continue "${channels[@]}" "$@"
fi
