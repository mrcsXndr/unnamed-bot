#!/usr/bin/env bash
# setup.sh — interactive-but-scriptable bootstrap wizard (macOS / Linux / Git Bash).
#
# Gets you from a fresh clone to a runnable bot:
#   1. Installs missing dependencies (scripts/install_deps.sh — Claude Code
#      CLI + PATH, Node.js, Python 3, pnpm, agent-browser, git). Per-component
#      opt-in; already-installed tools are detected and skipped.
#   2. Copies .env.example -> .env (if missing).
#   3. Prompts for the ONLY required inputs: bot name, Telegram bot token,
#      Telegram chat id. The token is validated against the Telegram API and
#      the chat id can be AUTO-DETECTED (just message your bot once).
#      (Telegram can be skipped — the bot still works in the terminal.)
#   4. Initializes the memory dirs + the cross-session recall DB.
#   5. Wires the Telegram channel plugin and PRE-AUTHORIZES your chat id
#      (no pairing dance needed).
#   6. Offers every automation as a yes/no OPT-IN (feature flags in .env):
#      Google Workspace, memory git sync, auto-commit, session debrief,
#      secrets backup. NOTHING GitHub- or backup-related is enabled unless
#      you say yes. (The supervisor/watchdog scheduled tasks are Windows-only
#      — run scripts\setup.ps1 there.)
#   7. Runs the bundled self-check (scripts/smoke_test.sh) and prints the
#      exact launch command.
#
# Idempotent: safe to re-run any time; it updates .env in place.
#
# Usage:
#   bash scripts/setup.sh                 # interactive wizard
#   bash scripts/setup.sh --help          # this help
#   bash scripts/setup.sh --dry-run       # print what would happen, change nothing
#   bash scripts/setup.sh --yes           # accept all defaults (non-interactive;
#                                         #   installs missing deps, opt-ins stay OFF)
#   bash scripts/setup.sh --skip-install  # skip the dependency installer step
#   bash scripts/setup.sh --bot-name X --tg-token T --tg-chat-id C [--yes]

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

DRY_RUN=0
ASSUME_YES=0
SKIP_INSTALL=0
ARG_BOT_NAME=""
ARG_TOKEN=""
ARG_CHAT_ID=""

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    --bot-name) ARG_BOT_NAME="${2:-}"; shift ;;
    --tg-token) ARG_TOKEN="${2:-}"; shift ;;
    --tg-chat-id) ARG_CHAT_ID="${2:-}"; shift ;;
    *) echo "setup: unknown flag $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# ask VAR "prompt" "default"
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}"
  local val=""
  if [ "$ASSUME_YES" = "1" ]; then
    val="$__default"
  else
    read -r -p "  $__prompt${__default:+ [$__default]}: " val || true
    val="${val:-$__default}"
  fi
  printf -v "$__var" '%s' "$val"
}

# ask_yn "prompt" -> returns 0 for yes. Default is always NO (opt-in).
ask_yn() {
  if [ "$ASSUME_YES" = "1" ]; then return 1; fi
  local ans=""
  read -r -p "  $1 [y/N]: " ans || true
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ask_yn_yes "prompt" -> default YES (only for non-automation steps like the
# self-check; the opt-in automations always go through ask_yn above).
ask_yn_yes() {
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi
  local ans=""
  read -r -p "  $1 [Y/n]: " ans || true
  case "$ans" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

# Python binary (either name), for JSON parsing + tool init.
PYBIN="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"

tg_api() { curl -sS -m 10 "https://api.telegram.org/bot${TOKEN}/$1" 2>/dev/null; }

# validate_token: 0 = OK-or-unknown (never block on network weirdness),
# 1 = Telegram definitively rejected the token. Sets TG_BOT_USERNAME.
TG_BOT_USERNAME=""
validate_token() {
  command -v curl >/dev/null 2>&1 || return 0
  local resp; resp="$(tg_api getMe)"
  case "$resp" in
    *'"ok":true'*)
      [ -n "$PYBIN" ] && TG_BOT_USERNAME="$(printf '%s' "$resp" | "$PYBIN" -c \
        "import json,sys;print(json.load(sys.stdin)['result'].get('username',''))" 2>/dev/null)"
      return 0 ;;
    *'"ok":false'*) return 1 ;;
    *) return 0 ;;
  esac
}

# detect_chat_id: print the chat id of the most recent DM to the bot ('' if none).
detect_chat_id() {
  command -v curl >/dev/null 2>&1 || return 0
  [ -n "$PYBIN" ] || return 0
  tg_api getUpdates | "$PYBIN" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    ids = [str(u["message"]["chat"]["id"])
           for u in d.get("result", []) if "message" in u]
    print(ids[-1] if ids else "")
except Exception:
    pass' 2>/dev/null
}

# set_env KEY VALUE — idempotent upsert into .env
set_env() {
  local key="$1" value="$2"
  [ "$DRY_RUN" = "1" ] && { note "(dry-run) would set $key=$value"; return 0; }
  if grep -qE "^${key}=" .env 2>/dev/null; then
    # portable in-place edit (BSD/GNU sed differ; use a temp file)
    local tmp; tmp="$(mktemp)"
    sed "s|^${key}=.*|${key}=${value}|" .env > "$tmp" && mv "$tmp" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

say ""
say "=== Bot setup wizard ==="
say ""

# --- 1. dependencies (detect + offer to install what's missing) ---------------
say "[1/7] Dependencies"
if [ "$SKIP_INSTALL" = "1" ]; then
  note "installer skipped (--skip-install)"
else
  DEP_FLAGS=()
  [ "$DRY_RUN" = "1" ] && DEP_FLAGS+=(--dry-run)
  [ "$ASSUME_YES" = "1" ] && DEP_FLAGS+=(--yes)
  bash "$REPO/scripts/install_deps.sh" ${DEP_FLAGS[@]+"${DEP_FLAGS[@]}"} || true
  # a JUST-installed python changes what setup itself can do — re-resolve
  hash -r 2>/dev/null || true
  PYBIN="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"
fi

# Re-verify the required four; without them the bot cannot launch.
MISSING=0
for tool in claude node git; do
  if command -v "$tool" >/dev/null 2>&1; then
    ver="$("$tool" --version 2>/dev/null | head -1)"
    note "ok: $tool ($ver)"
  else
    note "MISSING: $tool"
    MISSING=1
  fi
done
if [ -n "$PYBIN" ]; then
  note "ok: python ($("$PYBIN" --version 2>/dev/null | head -1))"
else
  note "MISSING: python"
  MISSING=1
fi
if [ "$MISSING" = "1" ]; then
  note ""
  note "Required tools are still missing. If they were JUST installed, open a"
  note "NEW terminal and re-run this wizard. Manual installs:"
  note "  claude  -> https://claude.com/claude-code"
  note "  python  -> https://python.org (3.10+)"
  note "  node    -> https://nodejs.org"
  note "  git     -> https://git-scm.com"
  [ "$DRY_RUN" = "1" ] || exit 1
fi

# --- 2. .env -------------------------------------------------------------------
say ""
say "[2/7] Config file (.env)"
if [ ! -f .env ]; then
  if [ "$DRY_RUN" = "1" ]; then
    note "(dry-run) would copy .env.example -> .env"
  else
    cp .env.example .env
    note "created .env from .env.example"
  fi
else
  note ".env already exists — keeping it (values you enter below overwrite in place)"
fi

# --- 3. required inputs ---------------------------------------------------------
say ""
say "[3/7] The three required inputs"
BOT_NAME="$ARG_BOT_NAME"
[ -n "$BOT_NAME" ] || ask BOT_NAME "What is your bot called?" "my-bot"
set_env BOT_NAME "$BOT_NAME"

TOKEN="$ARG_TOKEN"
if [ -z "$TOKEN" ] && [ "$ASSUME_YES" != "1" ]; then
  note "Telegram: create a bot with @BotFather (https://t.me/BotFather) and paste"
  note "its token here. Leave blank to skip Telegram (terminal-only bot)."
  ask TOKEN "Telegram bot token" ""
fi
CHAT_ID="$ARG_CHAT_ID"
if [ -n "$TOKEN" ]; then
  if validate_token; then
    [ -n "$TG_BOT_USERNAME" ] && note "token OK — your bot is @$TG_BOT_USERNAME"
  else
    note "WARNING: Telegram rejected that token. Double-check it with @BotFather."
    note "Continuing anyway — re-run setup to fix it."
  fi
  set_env TELEGRAM_BOT_TOKEN "$TOKEN"

  # chat id: auto-detect from the bot's inbox when possible
  if [ -z "$CHAT_ID" ]; then
    CHAT_ID="$(detect_chat_id)"
    [ -n "$CHAT_ID" ] && note "auto-detected your chat id: $CHAT_ID (from your last message to the bot)"
  fi
  if [ -z "$CHAT_ID" ] && [ "$ASSUME_YES" != "1" ]; then
    note "Send your bot ANY message on Telegram now, then press Enter to"
    note "auto-detect your chat id — or type the id manually."
    ask CHAT_ID "Telegram chat id (blank = auto-detect)" ""
    if [ -z "$CHAT_ID" ]; then
      CHAT_ID="$(detect_chat_id)"
      [ -n "$CHAT_ID" ] && note "auto-detected: $CHAT_ID"
    fi
  fi
  if [ -n "$CHAT_ID" ]; then
    set_env TELEGRAM_CHAT_ID "$CHAT_ID"
  else
    note "no chat id yet — the bot can't message you first; re-run setup after"
    note "messaging your bot once, or set TELEGRAM_CHAT_ID in .env by hand."
  fi
else
  note "skipping Telegram — you can re-run setup later to add it"
fi

# --- 4. memory dirs + recall DB ---------------------------------------------------
say ""
say "[4/7] Memory + recall index"
if [ "$DRY_RUN" = "1" ]; then
  note "(dry-run) would create memory/sessions, memory/metrics, memory/index + recall DB"
else
  mkdir -p memory/sessions memory/metrics
  PYTHONIOENCODING=utf-8 "${PYBIN:-python}" tools/v2/recall.py index >/dev/null 2>&1 \
    && note "recall index initialized (memory/index/recall.db)" \
    || note "recall index init failed (non-fatal; it retries at session start)"
fi

# --- 5. Telegram channel plugin -----------------------------------------------------
say ""
say "[5/7] Telegram channel"
PREPAIRED=0
if [ -n "${TOKEN:-}" ]; then
  # The official plugin reads its token from its own state .env. Write it
  # LF-only (bun chokes on CRLF).
  TG_DIR="$HOME/.claude/channels/telegram"
  if [ "$DRY_RUN" = "1" ]; then
    note "(dry-run) would write token to $TG_DIR/.env"
    [ -n "${CHAT_ID:-}" ] && note "(dry-run) would pre-authorize chat id $CHAT_ID (tools/tg/tg_pair.py)"
  else
    mkdir -p "$TG_DIR" 2>/dev/null || true
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$TG_DIR/.env"
    note "token written to $TG_DIR/.env"
    # Pre-authorize the owner's chat id -> no pairing dance on first message.
    if [ -n "${CHAT_ID:-}" ] && [ -n "$PYBIN" ] \
       && PYTHONIOENCODING=utf-8 "$PYBIN" tools/tg/tg_pair.py "$CHAT_ID" >/dev/null 2>&1; then
      PREPAIRED=1
      note "chat id $CHAT_ID pre-authorized — no pairing step needed"
    fi
  fi
  if [ "$PREPAIRED" != "1" ]; then
    note ""
    note "To pair your Telegram account (one-time):"
    note "  1. Launch the bot:   bash scripts/launch.sh"
    note "  2. Message your bot on Telegram — it replies with a pairing code"
    note "  3. In the Claude Code terminal run:  /telegram:access pair <code>"
  fi
else
  note "skipped (no token)"
fi

# --- 6. opt-in features ---------------------------------------------------------------
say ""
say "[6/7] Optional automations (all OFF unless you opt in)"

if ask_yn "Enable Google Workspace tools (calendar/gmail/tasks/sheets/drive)?"; then
  set_env FEATURE_GOOGLE 1
  note "-> FEATURE_GOOGLE=1. Finish OAuth:"
  note "   1. Create an OAuth client (Desktop) at https://console.cloud.google.com"
  note "      and enable the Calendar/Gmail/Tasks/Sheets/Drive APIs"
  note "   2. Save it as credentials.json in the repo root (see credentials.json.example)"
  note "   3. Run: python tools/google/google_workspace.py help  (first call opens a browser)"
else
  set_env FEATURE_GOOGLE 0
  note "-> Google tools off (the bot skips them cleanly)"
fi

if ask_yn "Sync memory/ to your git remote automatically (commit+push on stop)?"; then
  set_env FEATURE_MEMORY_SYNC 1
else
  set_env FEATURE_MEMORY_SYNC 0
fi

if ask_yn "Auto-commit ALL repo changes locally on session stop?"; then
  set_env FEATURE_AUTO_COMMIT 1
else
  set_env FEATURE_AUTO_COMMIT 0
fi

if ask_yn "Background LLM session debrief on stop (costs tokens)?"; then
  set_env FEATURE_SESSION_DEBRIEF 1
else
  set_env FEATURE_SESSION_DEBRIEF 0
fi

if ask_yn "Mirror secrets to a cloud/USB backup folder?"; then
  ask SYNC_PATH "Backup folder path" ""
  if [ -n "$SYNC_PATH" ]; then
    set_env FEATURE_SECRETS_BACKUP 1
    set_env SYNC_DRIVE_PATH "$SYNC_PATH"
  else
    note "no path given — leaving backups off"
    set_env FEATURE_SECRETS_BACKUP 0
  fi
else
  set_env FEATURE_SECRETS_BACKUP 0
fi

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    note ""
    note "Windows detected: the supervisor / watchdog / auto-restart layer is"
    note "installed from PowerShell — run:  pwsh -File scripts\\setup.ps1"
    ;;
  *)
    note ""
    note "Note: the supervisor/watchdog auto-restart layer is Windows-only"
    note "(scheduled tasks). See docs/SETUP.md for a cron/systemd sketch."
    ;;
esac

# --- 7. self-check + next step ---------------------------------------------------------
say ""
say "[7/7] Self-check"
if [ "$DRY_RUN" = "1" ]; then
  note "(dry-run) would run scripts/smoke_test.sh"
elif ask_yn_yes "Run the self-check now (verifies the harness, ~30s)?"; then
  if bash "$REPO/scripts/smoke_test.sh"; then
    note "self-check PASSED"
  else
    note "some self-check items failed (see above) — the bot may still launch;"
    note "re-run anytime with: bash scripts/smoke_test.sh"
  fi
else
  note "skipped. Run anytime with: bash scripts/smoke_test.sh"
fi

say ""
say "=== Setup complete ==="
say ""
say "NEXT STEP — launch your bot with exactly this command:"
say ""
say "    bash scripts/launch.sh"
say ""
if [ -n "${TOKEN:-}" ]; then
  if [ "$PREPAIRED" = "1" ]; then
    say "Then message your bot on Telegram — your chat id is already authorized,"
    say "so it will answer right away. (Or just talk in the terminal.)"
  else
    say "Then message your bot on Telegram and pair once with"
    say "/telegram:access pair <code>. (Or just talk in the terminal.)"
  fi
else
  say "Talk to it in the terminal. Re-run this wizard anytime to add Telegram."
fi
exit 0
