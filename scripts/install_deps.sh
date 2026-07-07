#!/usr/bin/env bash
# install_deps.sh — cross-platform dependency installer (macOS / Linux).
# On Git Bash (Windows) it delegates to scripts/install_deps.ps1.
#
# Installs everything the bot needs, PER-COMPONENT OPT-IN:
#   git            — version control (the repo is the bot's memory)
#   node           — Node.js + npm (statusline, memory-sync, browser tooling)
#   python         — Python 3.10+ (all tools/ + hooks)
#   claude         — Claude Code CLI (official native installer) + PATH registration
#   pnpm           — package manager for node projects (via npm)
#   agent-browser  — browser-automation CLI + its own isolated Chrome (via npm)
#
# Behaviour:
#   - Already-installed components are DETECTED and skipped (idempotent).
#   - Each missing component is a separate yes/no prompt (default Yes).
#   - A failing component NEVER aborts the run — it's reported in the summary
#     and the installer moves on.
#   - Package managers used: Homebrew on macOS (offers to install it if
#     missing), apt-get/dnf best-effort on Linux, npm for node-global tools.
#
# Usage:
#   bash scripts/install_deps.sh              # interactive
#   bash scripts/install_deps.sh --dry-run    # print what WOULD install; installs NOTHING
#   bash scripts/install_deps.sh --yes        # non-interactive: install all missing
#   bash scripts/install_deps.sh --skip agent-browser --skip pnpm
#
# Exit codes:
#   0  all good (or --dry-run)
#   1  a REQUIRED component (git/node/python/claude) is still missing afterwards

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=0
ASSUME_YES=0
SKIP=" "

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --skip) SKIP="$SKIP${2:-} "; shift ;;
    *) echo "install_deps: unknown flag $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- OS detection (Git Bash delegates to the PowerShell installer) -----------
OS=""
case "$(uname -s 2>/dev/null)" in
  Darwin) OS=mac ;;
  Linux)  OS=linux ;;
  MINGW*|MSYS*|CYGWIN*)
    say "Windows (Git Bash) detected — delegating to the PowerShell installer..."
    PS_SCRIPT="$REPO/scripts/install_deps.ps1"
    have cygpath && PS_SCRIPT="$(cygpath -w "$PS_SCRIPT")"
    PS_ARGS=()
    [ "$DRY_RUN" = "1" ] && PS_ARGS+=(-DryRun)
    [ "$ASSUME_YES" = "1" ] && PS_ARGS+=(-Yes)
    PS_EXE=""
    if have pwsh; then PS_EXE=pwsh
    elif have powershell.exe; then PS_EXE=powershell.exe
    elif [ -x "${SYSTEMROOT:-C:/Windows}/System32/WindowsPowerShell/v1.0/powershell.exe" ]; then
      PS_EXE="${SYSTEMROOT:-C:/Windows}/System32/WindowsPowerShell/v1.0/powershell.exe"
    fi
    if [ -z "$PS_EXE" ]; then
      echo "install_deps: PowerShell not found — run scripts/install_deps.ps1 from a PowerShell window instead." >&2
      exit 1
    fi
    exec "$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File "$PS_SCRIPT" ${PS_ARGS[@]+"${PS_ARGS[@]}"}
    ;;
  *) OS=linux ;;  # best effort for unknown unices
esac

# Linux package manager (best-effort)
PKG=none
if [ "$OS" = "linux" ]; then
  if have apt-get; then PKG=apt; elif have dnf; then PKG=dnf; fi
fi

SUDO=""
if [ "$OS" = "linux" ] && [ "$(id -u 2>/dev/null || echo 1)" != "0" ] && have sudo; then
  SUDO="sudo"
fi

# --- helpers -----------------------------------------------------------------

RESULTS=()   # lines: "component|status|detail"
add_result() { RESULTS+=("$1|$2|$3"); }

# ask_install "component" — default YES (these are prerequisites, not automations)
ask_install() {
  [ "$ASSUME_YES" = "1" ] && return 0
  [ "$DRY_RUN" = "1" ] && return 0
  local ans=""
  read -r -p "  Install $1? [Y/n]: " ans || true
  case "$ans" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

# run "description" cmd... — dry-run-aware executor; returns cmd's exit code
run() {
  local desc="$1"; shift
  if [ "$DRY_RUN" = "1" ]; then
    note "(dry-run) would run: $*"
    return 0
  fi
  note "-> $desc"
  "$@"
}

skipped() { case "$SKIP" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Make ~/.local/bin resolvable NOW and on future shells (idempotent).
ensure_local_bin_path() {
  case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
  [ "$DRY_RUN" = "1" ] && return 0
  local appended=0 rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if ! grep -qs '\.local/bin' "$rc"; then
      printf '\n# added by the bot installer — Claude Code lives in ~/.local/bin\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
      note "added ~/.local/bin to PATH in $rc"
    fi
    appended=1
  done
  if [ "$appended" = "0" ]; then
    printf '# added by the bot installer — Claude Code lives in ~/.local/bin\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.profile"
    note "created ~/.profile with ~/.local/bin on PATH"
  fi
}

# Homebrew bootstrap (macOS only; itself opt-in)
ensure_brew() {
  [ "$OS" = "mac" ] || return 1
  have brew && return 0
  say ""
  note "Homebrew (the macOS package manager) is needed to install this and is not present."
  if ask_install "Homebrew"; then
    run "installing Homebrew" /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
    # activate for THIS shell (Apple Silicon vs Intel prefix)
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
    if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
    have brew
  else
    return 1
  fi
}

# npm -g with a sudo retry (system-node Linux setups often need it)
npm_global_install() {
  local pkg="$1"
  run "npm install -g $pkg" npm install -g "$pkg" && return 0
  [ "$DRY_RUN" = "1" ] && return 0
  if [ -n "$SUDO" ]; then
    note "retrying with sudo..."
    run "sudo npm install -g $pkg" $SUDO npm install -g "$pkg"
    return $?
  fi
  return 1
}

pkg_install() {
  # pkg_install <mac-formula> <apt-pkgs...> — dnf uses the apt names too
  local formula="$1"; shift
  case "$OS" in
    mac)
      ensure_brew || { note "no Homebrew — install manually"; return 1; }
      run "brew install $formula" brew install "$formula"
      ;;
    linux)
      case "$PKG" in
        apt) run "apt-get install $*" $SUDO apt-get install -y "$@" ;;
        dnf) run "dnf install $*" $SUDO dnf install -y "$@" ;;
        *)   note "no apt-get/dnf found — install manually"; return 1 ;;
      esac
      ;;
  esac
}

# --- per-component detect + install -------------------------------------------

detect_git()    { have git; }
detect_node()   { have node; }
detect_python() { have python || have python3; }
detect_pnpm()   { have pnpm; }
detect_claude() { have claude || [ -x "$HOME/.local/bin/claude" ]; }
detect_ab() {
  have agent-browser && return 0
  local root; root="$(npm root -g 2>/dev/null || true)"
  [ -n "$root" ] && [ -d "$root/agent-browser" ]
}

version_of() {
  case "$1" in
    git)    git --version 2>/dev/null | head -1 ;;
    node)   node --version 2>/dev/null ;;
    python) { python --version 2>/dev/null || python3 --version 2>/dev/null; } | head -1 ;;
    pnpm)   pnpm --version 2>/dev/null ;;
    claude) { claude --version 2>/dev/null || "$HOME/.local/bin/claude" --version 2>/dev/null; } | head -1 ;;
    agent-browser) echo "installed" ;;
  esac
}

APT_UPDATED=0
maybe_apt_update() {
  [ "$PKG" = "apt" ] || return 0
  [ "$APT_UPDATED" = "1" ] && return 0
  run "apt-get update" $SUDO apt-get update -y || true
  APT_UPDATED=1
}

install_git()    { maybe_apt_update; pkg_install git git; }
install_node()   { maybe_apt_update; pkg_install node nodejs npm; }
install_python() { maybe_apt_update; pkg_install python python3; }

install_claude() {
  # Official native installer -> ~/.local/bin/claude, then PATH registration.
  run "Claude Code native installer (claude.ai/install.sh)" \
    bash -c "curl -fsSL https://claude.ai/install.sh | bash" || return 1
  ensure_local_bin_path
  return 0
}

install_pnpm() {
  detect_node || { note "pnpm needs Node.js — install node first"; return 1; }
  npm_global_install pnpm
}

install_ab() {
  detect_node || { note "agent-browser needs Node.js — install node first"; return 1; }
  npm_global_install agent-browser || return 1
  # download its isolated Chrome (can take a few minutes)
  local ab_bin="agent-browser"
  if ! have agent-browser; then
    # npm global bin dir: <prefix>/bin on *nix (npm root -g = <prefix>/lib/node_modules)
    local prefix; prefix="$(npm prefix -g 2>/dev/null || true)"
    [ -n "$prefix" ] && [ -x "$prefix/bin/agent-browser" ] && ab_bin="$prefix/bin/agent-browser"
  fi
  run "agent-browser install (downloads its isolated browser)" "$ab_bin" install
}

process() {
  # process <name> <detect-fn> <install-fn> <what>
  local name="$1" detect="$2" install="$3" what="$4"
  say ""
  if "$detect"; then
    note "ok: $name already installed ($(version_of "$name"))"
    add_result "$name" "already installed" "$(version_of "$name")"
    return 0
  fi
  if skipped "$name"; then
    note "skip: $name (--skip)"
    add_result "$name" "skipped" "--skip flag"
    return 0
  fi
  note "MISSING: $name — $what"
  if ! ask_install "$name"; then
    add_result "$name" "skipped" "declined"
    return 0
  fi
  "$install"
  if [ "$DRY_RUN" = "1" ]; then
    add_result "$name" "would install" "dry-run"
    return 0
  fi
  hash -r 2>/dev/null || true
  if "$detect"; then
    note "installed: $name ($(version_of "$name"))"
    add_result "$name" "INSTALLED" "$(version_of "$name")"
  else
    note "FAILED: $name did not resolve after install — see output above"
    add_result "$name" "FAILED" "not on PATH after install (a new terminal may fix it)"
  fi
}

# --- main ----------------------------------------------------------------------

say ""
say "=== Dependency installer ($OS) ==="
[ "$DRY_RUN" = "1" ] && say "    (dry-run: nothing will be installed)"

process git           detect_git    install_git    "version control; the repo is the bot's memory"
process node          detect_node   install_node   "Node.js + npm; runs the statusline and browser tooling"
process python        detect_python install_python "Python 3.10+; runs all the bot's tools and hooks"
process claude        detect_claude install_claude "the Claude Code CLI — the bot's brain"
process pnpm          detect_pnpm   install_pnpm   "node package manager (used by some optional tooling)"
process agent-browser detect_ab     install_ab     "browser automation with its own isolated Chrome"

# claude PATH sanity: installed but shell can't see it -> register + retry
if ! have claude && [ -x "$HOME/.local/bin/claude" ]; then
  ensure_local_bin_path
fi

say ""
say "=== Install summary ==="
for line in "${RESULTS[@]}"; do
  IFS='|' read -r comp status detail <<EOF
$line
EOF
  printf '  %-14s %-18s %s\n' "$comp" "$status" "$detail"
done

# Required-component gate (informative exit code; callers keep going on 1)
REQUIRED_MISSING=0
if [ "$DRY_RUN" != "1" ]; then
  for c in git node claude; do
    have "$c" || { REQUIRED_MISSING=1; say "  !! required: '$c' still not resolvable"; }
  done
  detect_python || { REQUIRED_MISSING=1; say "  !! required: 'python' still not resolvable"; }
  if [ "$REQUIRED_MISSING" = "1" ]; then
    say ""
    say "Some required tools are still missing. If they were JUST installed,"
    say "open a NEW terminal (PATH refresh) and re-run:  bash scripts/setup.sh"
    exit 1
  fi
fi

say ""
say "All required dependencies are present."
exit 0
