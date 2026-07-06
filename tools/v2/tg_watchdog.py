#!/usr/bin/env python3
"""tg_watchdog.py — detect a dead Telegram long-poller and auto-heal by restart.

WHY this exists: the TG Bot API allows only ONE getUpdates long-poller per bot
token. When a second the bot instance steals the slot, the original poller 409s into
a permanent dead state — the claude process stays alive (outbound tg_send still
works) but inbound messages are silently dropped. This watchdog probes the slot,
and when it confirms the poller is dead AND the session is idle, it triggers the
same detached restart dance used by /update (reusing update_restart.py's
machinery), which re-acquires the lock and resumes polling.

Probe classification (getUpdates?timeout=0&offset=-1&limit=1):
  HTTP 409  -> ALIVE   (another poller — our own — holds the slot: healthy)
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
  --probe-only   print ALIVE/DEAD/UNKNOWN and exit; no heal, no alert.
  --dry-run      classify + log the would-do action; no restart, no alert.

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
HEAL_LOG = REPO_ROOT / "memory" / "metrics" / "tg_heals.log"
TG_SEND = REPO_ROOT / "tools" / "tg" / "tg_send.py"

# Backoff: refuse > MAX_HEALS within WINDOW_MIN rolling minutes.
MAX_HEALS = 3
WINDOW_MIN = 30
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


def heal(dry_run: bool) -> int:
    """Confirmed-DEAD path: enforce backoff, check idle gate, then restart.
    Always returns 0 (heal is best-effort; never a hard failure)."""
    recent = _recent_heal_count()
    if recent >= MAX_HEALS:
        _log(f"heal cap hit ({recent}/{WINDOW_MIN}m) — refusing restart")
        if not dry_run:
            _send_tg("TG poller dead but heal cap hit "
                     f"(3/30m) — run `the bot` manually")
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
        _send_tg("TG poller dead — could not resolve the bot PID, "
                 "run `the bot` manually")
        return 0

    _log(f"heal: poller DEAD + idle -> restart-bot -OldPid {old_pid}")
    _send_tg("TG poller dead — auto-healing (restart)")
    _spawn_restart_detached(old_pid, dry_run=False)
    _terminate_pid(old_pid)
    return 0


def main(argv: list[str]) -> int:
    probe_only = "--probe-only" in argv[1:]
    dry_run = "--dry-run" in argv[1:]

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
    return heal(dry_run=dry_run)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # fail-open: never non-zero, never a spurious restart
        _log(f"FAIL-OPEN: unhandled exception: {e!r}")
        sys.exit(0)
