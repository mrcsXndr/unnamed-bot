#!/usr/bin/env python3
"""tg_watchdog.py — detect a dead Telegram bridge and auto-heal, bridge-first.

WHY this exists: the TG Bot API allows only ONE getUpdates long-poller per bot
token. When a second bot instance steals the slot — OR the plugin's own poller
subprocess wedges/crashes — the original poller 409s into a permanent dead state
or simply stops. CRITICALLY, the claude.exe process stays ALIVE the whole time
(outbound tg_send still works), but inbound messages are silently dropped. This
is the case an earlier process-only watchdog MISSED: it only resurrected fully-dead
PROCESSES and never noticed a LIVE session whose bridge had died.

Two distinct failure modes this watchdog now covers:
  (a) DEAD PROCESS — the whole claude session is gone. (Handled by the
      SUPERVISOR cold-start, not here: this watchdog finds the bot by walking its
      OWN parent chain, so it can only heal a session it is a descendant of.)
  (b) LIVE SESSION, DEAD BRIDGE — claude.exe is alive but the Telegram poller
      subprocess (tracked by ~/.claude/channels/telegram/bot.pid) is wedged in
      a 409 standoff or crashed. THIS is the watchdog's primary job.

HEAL STRATEGY — bridge-first, session-restart only as a fallback:
  1. BRIDGE KICK (preferred, works even when the session is BUSY): the poller is
     a CHILD subprocess of the live claude — kill JUST that bot.pid process. The
     channel-plugin host stays loaded in claude and RE-SPAWNS a fresh poller,
     which re-claims the getUpdates slot. The claude session, its conversation,
     and all in-flight work are UNTOUCHED. No --continue, no context rebuild.
     This is the fix for the "busy session, dead bridge" trap where the old
     idle-gated full-restart would defer INDEFINITELY and leave the bot deaf.
  2. FULL RESTART (fallback): only if the bridge-kick did NOT restore polling
     (re-probe still DEAD), fall back to the idle-gated detached session restart
     (reusing update_restart.py's machinery). This covers the rarer case where
     the plugin host itself is wedged and won't respawn.

Probe classification (getUpdates?timeout=0&offset=-1&limit=1):
  HTTP 409  -> ALIVE   (a poller — ours — holds the slot: healthy)
  HTTP 200  -> (slot free this instant: NOT proof of death — see below)
  other/net -> UNKNOWN (transient/network/token: take no action)

CRITICAL — the official plugin polls in INTERVALS, not one continuous long-poll.
So a healthy poller's slot ALTERNATES: 409 mid-poll, 200 in the gap between
polls (observed live: 200/409/200/409/200 at ~2s spacing). A single 200 — or
even several — therefore does NOT mean dead. We sample the slot PROBE_SAMPLES
times across a window LONGER than the poll cycle:
  - ANY 409 in the window      -> ALIVE (early exit; a live poll exists)
  - EVERY sample is 200         -> DEAD  (slot never claimed across the window)
  - 200s mixed with net-UNKNOWN -> UNKNOWN (ambiguous; take no action)
This defeats the false-DEAD an interval-poller would otherwise trigger.

Flags:
  --probe-only    print ALIVE/DEAD/UNKNOWN and exit; no heal, no alert.
  --dry-run       classify + log the would-do action; no kick/restart, no alert.
  --no-kick       skip the bridge-kick; go straight to the idle-gated full
                  restart (the legacy behaviour, for debugging).
  --kick-only     do ONLY the bridge-kick on confirmed DEAD; never escalate to a
                  full session restart (useful when the session must not die).

Fail-open: any exception in main() is logged and the process exits 0. Never
non-zero, never a spurious restart.
"""
from __future__ import annotations

import datetime
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "v2"))

# Reuse update_restart.py's proven machinery (proc-walk, restart-spawn,
# terminate, idle gate). Do NOT reinvent any of this.
from update_restart import (  # noqa: E402
    gate_session_idle,
    _live_claude_pid,
    _spawn_restart_detached,
    _terminate_pid,
)

ENV_FILE = Path(os.environ.get("USERPROFILE", "")) / ".claude" / "channels" / "telegram" / ".env"
BOT_PID_FILE = Path(os.environ.get("USERPROFILE", "")) / ".claude" / "channels" / "telegram" / "bot.pid"
HEAL_LOG = REPO_ROOT / "memory" / "metrics" / "tg_heals.log"
TG_SEND = REPO_ROOT / "tools" / "tg_send.py"
PS_EXE = os.path.join(
    os.environ.get("SystemRoot", r"C:\Windows"),
    "System32", "WindowsPowerShell", "v1.0", "powershell.exe",
)

# Backoff: refuse > MAX_HEALS within WINDOW_MIN rolling minutes.
MAX_HEALS = 3
WINDOW_MIN = 30
# Names a legitimate channel-plugin poller process can have. Guards against
# killing a reused PID that is no longer the poller.
POLLER_NAMES = ("bun", "node", "bun.exe", "node.exe")
# After a bridge-kick, wait this long for the plugin host to respawn the poller
# and re-claim the slot before re-probing to confirm the heal worked.
KICK_RESETTLE_S = 12
# Liveness sampling. The plugin interval-polls, so the slot flaps 409/200 on a
# ~2-4s cycle. Sample across a window LONGER than that cycle: a healthy poller
# WILL show >=1 409; a dead one is all-200 the whole window. 8 samples x 2s
# ~= 16s window (spans several poll cycles).
PROBE_SAMPLES = 8
PROBE_SLEEP_S = 2
PROBE_TIMEOUT_S = 10

ALIVE = "ALIVE"
DEAD = "DEAD"
UNKNOWN = "UNKNOWN"
FREE = "FREE"  # slot unclaimed this instant (HTTP 200) — internal to _probe_once


def _now_iso() -> str:
    return datetime.datetime.now().isoformat(timespec="seconds")


def _log(line: str) -> None:
    """Append one ISO-stamped line to the heal log. Best-effort."""
    try:
        HEAL_LOG.parent.mkdir(parents=True, exist_ok=True)
        with HEAL_LOG.open("a", encoding="utf-8") as fh:
            fh.write(f"{_now_iso()}  {line}\n")
    except Exception:
        pass


def _read_token() -> str | None:
    try:
        for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line.startswith("TELEGRAM_BOT_TOKEN="):
                val = line.split("=", 1)[1].strip().strip('"').strip("'")
                return val or None
    except OSError:
        return None
    return None


def _send_tg(text: str) -> None:
    """Outbound alert. Unaffected by poller death. Let the status footer append
    (no --no-status), per brief."""
    try:
        subprocess.run(
            [sys.executable or "python", str(TG_SEND), "--quiet", text],
            capture_output=True, text=True, timeout=20, encoding="utf-8",
        )
    except Exception as e:
        _log(f"tg_send failed: {e}")


def _probe_once(token: str) -> str:
    """Single getUpdates probe. Returns:
      ALIVE   on HTTP 409 (an active getUpdates holds the slot)
      "FREE"  on HTTP 200 (slot unclaimed THIS instant — not proof of death)
      UNKNOWN on network/timeout/other HTTP."""
    url = (f"https://api.telegram.org/bot{token}/getUpdates"
           f"?timeout=0&offset=-1&limit=1")
    req = urllib.request.Request(url, headers={"User-Agent": "Bot-TG-Watchdog/1"})
    try:
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT_S) as resp:
            return ALIVE if resp.status == 409 else FREE
    except urllib.error.HTTPError as e:
        if e.code == 409:
            return ALIVE
        return UNKNOWN
    except Exception:
        # Network/timeout/DNS/other -> indeterminate, take no action.
        return UNKNOWN


def classify(token: str) -> str:
    """Sample the poll slot across a window LONGER than the plugin's poll cycle.
    The plugin interval-polls, so a healthy slot flaps 409/200 — a single (or
    several) 200 does NOT mean dead. Verdict:
      - ANY 409 seen          -> ALIVE  (early exit: a live poll exists)
      - EVERY sample is 200    -> DEAD  (slot never claimed the whole window)
      - 200s + any net-UNKNOWN -> UNKNOWN (ambiguous; take no action)."""
    saw_unknown = False
    for i in range(PROBE_SAMPLES):
        r = _probe_once(token)
        if r == ALIVE:
            return ALIVE
        if r == UNKNOWN:
            saw_unknown = True
        # r == FREE (200) just continues sampling
        if i < PROBE_SAMPLES - 1:
            time.sleep(PROBE_SLEEP_S)
    # No 409 in the entire window.
    return UNKNOWN if saw_unknown else DEAD


def _recent_heal_count(now: float | None = None) -> int:
    """Count heal actions logged within the rolling WINDOW_MIN window."""
    now = now if now is not None else time.time()
    cutoff = now - WINDOW_MIN * 60
    count = 0
    try:
        for raw in HEAL_LOG.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or " heal" not in line:
                continue
            stamp = line.split("  ", 1)[0]
            try:
                ts = datetime.datetime.fromisoformat(stamp).timestamp()
            except ValueError:
                continue
            if ts >= cutoff:
                count += 1
    except OSError:
        return 0
    return count


def _read_bot_pid() -> int | None:
    """Read ~/.claude/channels/telegram/bot.pid (the plugin's poller PID).
    BOM-safe: a UTF-8 BOM defeats int(), so pull the first digit-run. None if
    absent/unreadable/no digits."""
    try:
        raw = BOT_PID_FILE.read_text(encoding="utf-8")
    except OSError:
        return None
    import re
    m = re.search(r"\d+", raw)
    return int(m.group(0)) if m else None


def _proc_name(pid: int) -> str | None:
    """Lowercased process name for pid, or None if not alive. Used to guard the
    kill against PID reuse (only kill if it still looks like the poller)."""
    try:
        r = subprocess.run(
            [PS_EXE, "-NoProfile", "-NonInteractive", "-Command",
             f"(Get-Process -Id {pid} -ErrorAction SilentlyContinue).ProcessName"],
            capture_output=True, text=True, timeout=15, encoding="utf-8",
        )
        name = (r.stdout or "").strip().lower()
        return name or None
    except Exception:
        return None


def _kill_pid(pid: int) -> None:
    try:
        subprocess.run(
            [PS_EXE, "-NoProfile", "-NonInteractive", "-Command",
             f"Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue"],
            capture_output=True, text=True, timeout=15,
        )
    except Exception as e:
        _log(f"kill_pid({pid}) failed: {e}")


def bridge_kick(token: str, dry_run: bool) -> bool:
    """Restart JUST the Telegram bridge in a LIVE claude session — no session
    restart, works even when the session is BUSY.

    The poller is a CHILD subprocess of the live claude (the channel-plugin
    host). Killing that subprocess by its bot.pid leaves claude.exe + the plugin
    host loaded; the host then re-spawns a fresh poller that re-claims the slot.

    Returns True if, after the kick, a re-probe shows the slot is ALIVE again
    (bridge restored). Returns False if there was no poller to kick, the kick
    couldn't be done, or polling did NOT come back (caller may escalate to a
    full restart). Never raises — best-effort."""
    bot_pid = _read_bot_pid()
    if bot_pid is None:
        _log("bridge-kick: no bot.pid (poller PID unknown) — cannot kick, "
             "escalate to full restart")
        return False

    name = _proc_name(bot_pid)
    if name is None:
        # bot.pid points at a dead process already — the poller subprocess is
        # gone but the slot is still 409-wedged on Telegram's side (or the host
        # hasn't respawned). Nothing to kick; let it escalate.
        _log(f"bridge-kick: bot.pid={bot_pid} not alive (poller already gone) "
             "— escalate to full restart")
        return False
    if not any(name == n or name == n.removesuffix(".exe") for n in POLLER_NAMES):
        _log(f"bridge-kick: bot.pid={bot_pid} is '{name}', not a known poller "
             "name (PID reuse?) — refusing to kill, escalate")
        return False

    if dry_run:
        _log(f"DRY-RUN bridge-kick: WOULD kill poller bot.pid={bot_pid} "
             f"({name}); plugin host would respawn it.")
        return True  # report success in dry-run so we don't also dry-run a restart

    _log(f"bridge-kick: killing wedged poller bot.pid={bot_pid} ({name}); "
         "plugin host will respawn a fresh poller")
    _send_tg("TG bridge dead in a live session — kicking poller (session stays up)")
    _kill_pid(bot_pid)

    # Give the plugin host time to notice the child died and respawn it.
    time.sleep(KICK_RESETTLE_S)

    verdict = classify(token)
    if verdict == ALIVE:
        _log("bridge-kick: SUCCESS — poller respawned, slot ALIVE again")
        _send_tg("TG bridge back up (poller respawned, session never dropped)")
        return True
    _log(f"bridge-kick: slot still {verdict} after kick — escalating to full restart")
    return False


def heal(dry_run: bool, kick: bool = True, kick_only: bool = False) -> int:
    """Confirmed-DEAD path. Bridge-first: try a poller-only kick (cheap, keeps
    the session alive, works while BUSY); only if that fails to restore polling
    fall back to the idle-gated full session restart.
    Always returns 0 (heal is best-effort; never a hard failure)."""
    recent = _recent_heal_count()
    if recent >= MAX_HEALS:
        _log(f"heal cap hit ({recent}/{WINDOW_MIN}m) — refusing any heal")
        if not dry_run:
            _send_tg("TG bridge dead but heal cap hit "
                     "(3/30m) — run `mybot` manually")
        return 0

    token = _read_token()
    # 1) Bridge-kick first (unless explicitly disabled). This is the live-session
    #    fix: it does NOT require the idle gate, so a BUSY session with a dead
    #    bridge is healed immediately instead of deferring forever.
    if kick and token:
        _log(f"heal: confirmed DEAD bridge — bridge-kick first")
        if bridge_kick(token, dry_run=dry_run):
            return 0  # bridge restored without touching the session
        if kick_only:
            _log("heal: --kick-only set and kick did not restore polling — "
                 "NOT escalating to full restart")
            if not dry_run:
                _send_tg("TG bridge kick failed; --kick-only so NOT restarting "
                         "session — run `mybot` if it stays down")
            return 0
    elif kick_only:
        _log("heal: --kick-only but no token/kick disabled — nothing to do")
        return 0
    return _full_restart(dry_run)


def _full_restart(dry_run: bool) -> int:
    """Fallback: idle-gated detached SESSION restart (legacy behaviour).
    Always returns 0 (best-effort)."""
    recent = _recent_heal_count()
    if recent >= MAX_HEALS:
        _log(f"heal cap hit ({recent}/{WINDOW_MIN}m) — refusing restart")
        if not dry_run:
            _send_tg("TG poller dead but heal cap hit "
                     f"(3/30m) — run `mybot` manually")
        return 0

    idle, why = gate_session_idle()
    if not idle:
        _log(f"deferred: BUSY — {why}")
        if not dry_run:
            _send_tg("TG poller down, deferring restart (session busy)")
        return 0

    old_pid = _live_claude_pid()
    if dry_run:
        _log(f"DRY-RUN heal: would restart-bot -OldPid {old_pid} "
             f"(idle: {why})")
        return 0

    if old_pid is None:
        _log("heal: could NOT resolve live claude PID — not restarting blind")
        _send_tg("TG poller dead — could not resolve bot PID, "
                 "run `mybot` manually")
        return 0

    _log(f"heal: poller DEAD + idle -> restart-bot -OldPid {old_pid}")
    _send_tg("TG poller dead — auto-healing (restart)")
    _spawn_restart_detached(old_pid, dry_run=False)
    _terminate_pid(old_pid)
    return 0


def main(argv: list[str]) -> int:
    probe_only = "--probe-only" in argv[1:]
    dry_run = "--dry-run" in argv[1:]
    no_kick = "--no-kick" in argv[1:]
    kick_only = "--kick-only" in argv[1:]

    token = _read_token()
    if not token:
        # No token -> cannot probe -> UNKNOWN, take no action (fail-open).
        if probe_only:
            print(UNKNOWN)
        else:
            _log("UNKNOWN: no TELEGRAM_BOT_TOKEN — no action")
        return 0

    verdict = classify(token)

    if probe_only:
        print(verdict)
        return 0

    if verdict == ALIVE:
        # Healthy: stay quiet (don't spam the heal log on every tick).
        return 0
    if verdict == UNKNOWN:
        _log("UNKNOWN: indeterminate probe — no action")
        return 0

    # verdict == DEAD
    return heal(dry_run=dry_run, kick=not no_kick, kick_only=kick_only)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # fail-open: never non-zero, never a spurious restart
        _log(f"FAIL-OPEN: unhandled exception: {e!r}")
        sys.exit(0)
