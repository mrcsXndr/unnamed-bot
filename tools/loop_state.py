#!/usr/bin/env python3
"""
loop_state.py — autonomous-loop state machine + auto-pause for Goosey.

Tracks consecutive no-op ticks, daily tick budget, paused state. Each cron-fired
tick calls `loop_state.py check` first — if exit code 1, the tick exits early
without doing anything (near-zero token cost). On real-work ticks, calls
`loop_state.py work` to reset the no-op counter. On no-op ticks, calls
`loop_state.py noop` — after 5 consecutive no-ops, auto-pauses with reason.

State file: goose-bot/.autoloop_state.json
Sentinel file: goose-bot/.autoloop_paused (presence = paused, content = reason)

Usage:
    python tools/loop_state.py check                  # exit 0 = run tick, 1 = skip
    python tools/loop_state.py work                   # reset noop counter, mark a real-work tick
    python tools/loop_state.py noop                   # increment noop counter; auto-pause if >= 5
    python tools/loop_state.py pause "reason"
    python tools/loop_state.py resume
    python tools/loop_state.py status                 # human-readable summary
    python tools/loop_state.py reset                  # clear all state, useful for testing

Configuration (top of file):
    NOOP_THRESHOLD = 5      # consecutive no-ops before auto-pause
    DAILY_TICK_CAP = 200    # max ticks per UTC day
    DAILY_RESET_HOUR = 0    # midnight UTC

The check command's exit code is the contract:
    0  = loop should run this tick
    1  = loop should skip this tick (paused, capped, or error)

Designed to be called from a Bash wrapper that the cron prompt invokes FIRST.
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATE_FILE = ROOT / ".autoloop_state.json"
PAUSE_FILE = ROOT / ".autoloop_paused"

NOOP_THRESHOLD = 5
# DAILY_TICK_CAP removed 2026-04-09: stop looping when you
# actually think you're done, not arbitrary number based". The auto-pause via
# 5 consecutive no-op ticks (NOOP_THRESHOLD) is the qualitative stop signal —
# if Goosey can't find work 5 ticks in a row, the loop pauses itself. The
# numeric cap was a token-budget guardrail from the early days that no longer
# matches the intended UX. We still keep `ticks_today` in the state for
# observability but it doesn't gate anything.
DAILY_TICK_CAP = 10**9

# A real tick must have fired within this many minutes for the loop to be
# considered "running" (drives the `running` subcommand). The cron tick fires
# every 10 min so 15 gives one full miss of grace.
RUNNING_FRESH_MIN = 15


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def today_key() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def load() -> dict:
    if not STATE_FILE.exists():
        return {
            "consecutive_noops": 0,
            "last_tick_at": None,
            "last_tick_outcome": None,
            "ticks_today": 0,
            "ticks_today_date": today_key(),
            "lifetime_ticks": 0,
            "lifetime_noops": 0,
            "lifetime_works": 0,
            "lifetime_pauses": 0,
        }
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {
            "consecutive_noops": 0,
            "last_tick_at": None,
            "last_tick_outcome": None,
            "ticks_today": 0,
            "ticks_today_date": today_key(),
            "lifetime_ticks": 0,
            "lifetime_noops": 0,
            "lifetime_works": 0,
            "lifetime_pauses": 0,
        }


def save(state: dict):
    STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")


def is_paused() -> tuple[bool, str]:
    if PAUSE_FILE.exists():
        try:
            reason = PAUSE_FILE.read_text(encoding="utf-8").strip()
        except Exception:
            reason = "(no reason captured)"
        return True, reason
    return False, ""


def set_paused(reason: str):
    PAUSE_FILE.write_text(f"{now_iso()}\n{reason}\n", encoding="utf-8")
    state = load()
    state["lifetime_pauses"] = state.get("lifetime_pauses", 0) + 1
    save(state)


def clear_paused():
    if PAUSE_FILE.exists():
        PAUSE_FILE.unlink()


def tick_today(state: dict) -> dict:
    """Reset daily counter if we crossed midnight UTC."""
    today = today_key()
    if state.get("ticks_today_date") != today:
        state["ticks_today"] = 0
        state["ticks_today_date"] = today
    return state


def cmd_check() -> int:
    """Exit 0 if loop should run, 1 if it should skip."""
    paused, reason = is_paused()
    if paused:
        sys.stderr.write(f"loop_state: PAUSED ({reason}), skipping tick\n")
        return 1
    state = load()
    state = tick_today(state)
    if state["ticks_today"] >= DAILY_TICK_CAP:
        sys.stderr.write(
            f"loop_state: DAILY CAP reached ({state['ticks_today']}/{DAILY_TICK_CAP}), skipping tick\n"
        )
        save(state)
        return 1
    return 0


def cmd_work() -> int:
    """Mark a real-work tick. Resets the noop counter."""
    state = load()
    state = tick_today(state)
    state["consecutive_noops"] = 0
    state["last_tick_at"] = now_iso()
    state["last_tick_outcome"] = "work"
    state["ticks_today"] = state.get("ticks_today", 0) + 1
    state["lifetime_ticks"] = state.get("lifetime_ticks", 0) + 1
    state["lifetime_works"] = state.get("lifetime_works", 0) + 1
    save(state)
    sys.stderr.write(
        f"loop_state: work tick recorded ({state['ticks_today']}/{DAILY_TICK_CAP} today, "
        f"{state['lifetime_ticks']} lifetime)\n"
    )
    return 0


def cmd_noop() -> int:
    """Mark a no-op tick. Auto-pauses after NOOP_THRESHOLD consecutive."""
    state = load()
    state = tick_today(state)
    state["consecutive_noops"] = state.get("consecutive_noops", 0) + 1
    state["last_tick_at"] = now_iso()
    state["last_tick_outcome"] = "noop"
    state["ticks_today"] = state.get("ticks_today", 0) + 1
    state["lifetime_ticks"] = state.get("lifetime_ticks", 0) + 1
    state["lifetime_noops"] = state.get("lifetime_noops", 0) + 1
    save(state)
    sys.stderr.write(
        f"loop_state: noop tick #{state['consecutive_noops']} of {NOOP_THRESHOLD}\n"
    )
    if state["consecutive_noops"] >= NOOP_THRESHOLD:
        set_paused(f"auto-paused after {NOOP_THRESHOLD} consecutive no-op ticks")
        sys.stderr.write(
            f"loop_state: AUTO-PAUSED (hit {NOOP_THRESHOLD} consecutive no-ops). "
            f"Resume via `python tools/loop_state.py resume` or new TG message arrival.\n"
        )
        return 2
    return 0


def cmd_pause(reason: str) -> int:
    set_paused(reason)
    sys.stderr.write(f"loop_state: paused ({reason})\n")
    return 0


def cmd_resume() -> int:
    if not PAUSE_FILE.exists():
        sys.stderr.write("loop_state: not currently paused\n")
        return 0
    clear_paused()
    state = load()
    state["consecutive_noops"] = 0
    save(state)
    sys.stderr.write("loop_state: resumed (noop counter reset)\n")
    return 0


def cmd_status() -> int:
    state = load()
    state = tick_today(state)
    paused, reason = is_paused()
    print(f"loop_state status @ {now_iso()}")
    print(f"  paused: {paused}")
    if paused:
        print(f"  reason: {reason}")
    print(f"  consecutive_noops: {state['consecutive_noops']} (threshold: {NOOP_THRESHOLD})")
    print(f"  ticks_today: {state['ticks_today']}/{DAILY_TICK_CAP}")
    print(f"  last_tick_at: {state.get('last_tick_at') or 'never'}")
    print(f"  last_tick_outcome: {state.get('last_tick_outcome') or 'never'}")
    print(f"  lifetime_ticks: {state.get('lifetime_ticks', 0)}")
    print(f"  lifetime_works: {state.get('lifetime_works', 0)}")
    print(f"  lifetime_noops: {state.get('lifetime_noops', 0)}")
    print(f"  lifetime_pauses: {state.get('lifetime_pauses', 0)}")
    return 0


def cmd_running() -> int:
    """Exit 0 if the autonomous loop is currently active, 1 if it's not.

    "Active" means: not paused AND a real tick has fired in the last
    RUNNING_FRESH_MIN minutes. Used by auto_unstick.py and auto_compactor.ps1
    to suppress themselves when the user is using Claude Code interactively
    rather than running the autonomous loop — user request:
    "auto unstick should only happen if loop is running ofc".
    """
    paused, _reason = is_paused()
    if paused:
        return 1
    state = load()
    last_tick = state.get("last_tick_at")
    if not last_tick:
        return 1
    try:
        last_dt = datetime.fromisoformat(last_tick)
    except Exception:
        return 1
    age_min = (datetime.now(timezone.utc) - last_dt.astimezone(timezone.utc)).total_seconds() / 60
    if age_min > RUNNING_FRESH_MIN:
        return 1
    return 0


def cmd_reset() -> int:
    if STATE_FILE.exists():
        STATE_FILE.unlink()
    if PAUSE_FILE.exists():
        PAUSE_FILE.unlink()
    sys.stderr.write("loop_state: reset (state + pause file deleted)\n")
    return 0


def main():
    p = argparse.ArgumentParser(description="Autonomous-loop state machine + auto-pause")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("check", help="Exit 0 if tick should run, 1 if should skip")
    sub.add_parser("work", help="Mark a real-work tick (reset noop counter)")
    sub.add_parser("noop", help="Mark a no-op tick (increment counter, may auto-pause)")
    p_pause = sub.add_parser("pause", help="Manually pause the loop")
    p_pause.add_argument("reason", nargs="?", default="manual pause")
    sub.add_parser("resume", help="Resume the loop after pause")
    sub.add_parser("status", help="Print current state")
    sub.add_parser("running", help="Exit 0 if loop is currently active, 1 if not (used by auto_unstick + auto_compactor)")
    sub.add_parser("reset", help="Clear all state (testing only)")

    args = p.parse_args()

    handlers = {
        "check": cmd_check,
        "work": cmd_work,
        "noop": cmd_noop,
        "pause": lambda: cmd_pause(args.reason),
        "resume": cmd_resume,
        "status": cmd_status,
        "running": cmd_running,
        "reset": cmd_reset,
    }
    sys.exit(handlers[args.cmd]())


if __name__ == "__main__":
    main()
