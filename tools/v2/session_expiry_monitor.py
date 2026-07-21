#!/usr/bin/env python3
"""session_expiry_monitor.py — warn on Telegram before the Claude login session expires.

Why this exists: when the Claude Code OAuth *login session* lapses, the bot
silently stops being able to reach the API — the operator just sees it go dark
and has to re-run `/login` by hand. This monitor runs OUTSIDE the CC process (on
the supervisor tick, like the other notify-only monitors) so it can warn AHEAD of
time while the session is still alive.

Signal: `~/.claude/.credentials.json` -> `claudeAiOauth.refreshTokenExpiresAt`
(ms epoch). Two distinct expiries live there:
  - `expiresAt`             = the ACCESS token; CC auto-refreshes it every few
                              hours. NOT the concern — ignore it.
  - `refreshTokenExpiresAt` = the LOGIN SESSION. When this lapses, the refresh
                              chain is dead and a manual `/login` is required.
                              THIS is what we warn on.

Behaviour (escalation, NOT nagging):
  - Compute time left until refreshTokenExpiresAt.
  - Map it to a tier:  OK > WARN(<=--warn-days, default 3d) > URGENT(<=24h) >
    EXPIRED(<=0). Send ONE Telegram message the first time each tier is entered
    and only escalate upward — the same tier never re-alerts, so the worst case
    is 3 messages over the final 3 days, each one meaningfully closer.
  - A changed refreshTokenExpiresAt (a fresh `/login` / token rotation extended
    the session) RESETS the tier tracking, so the next approach warns cleanly.
  - Send via tg_send.py (keeps the status footer).

STRICTLY FAIL-OPEN: any exception -> log to stderr + exit 0. Never breaks the tick.
Flags: --dry-run (print, does NOT stamp state), --probe-only (report, no send/stamp),
--warn-days N (default 3), --creds PATH (override credential file).
"""
from __future__ import annotations
import argparse, json, os, subprocess, sys
from datetime import datetime, timezone

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CREDS = os.environ.get("CLAUDE_CREDS_PATH", os.path.expanduser("~/.claude/.credentials.json"))
STATE = os.path.join(REPO, "memory", "metrics", "session_expiry_state.json")
TG_SEND = os.path.join(REPO, "tools", "tg", "tg_send.py")

# Tier ranks — higher = more urgent. We only ever alert UP the ladder.
TIER_OK, TIER_WARN, TIER_URGENT, TIER_EXPIRED = 0, 1, 2, 3
TIER_NAME = {TIER_OK: "ok", TIER_WARN: "warn", TIER_URGENT: "urgent", TIER_EXPIRED: "expired"}


def _log(msg: str) -> None:
    print(f"[session_expiry] {msg}", file=sys.stderr)


def read_refresh_expiry(path: str):
    """Return refreshTokenExpiresAt as an aware UTC datetime, or None."""
    d = json.load(open(path, encoding="utf-8"))
    oauth = d.get("claudeAiOauth") or {}
    raw = oauth.get("refreshTokenExpiresAt")
    if not isinstance(raw, (int, float)) or raw <= 0:
        return None
    return datetime.fromtimestamp(raw / 1000.0, tz=timezone.utc)


def tier_for(hours_left: float, warn_days: int) -> int:
    if hours_left <= 0:
        return TIER_EXPIRED
    if hours_left <= 24:
        return TIER_URGENT
    if hours_left <= warn_days * 24:
        return TIER_WARN
    return TIER_OK


def fmt_left(hours_left: float) -> str:
    if hours_left <= 0:
        return "now"
    if hours_left < 48:
        return f"{hours_left:.0f}h"
    return f"{hours_left / 24:.1f}d"


def load_state() -> dict:
    try:
        return json.load(open(STATE, encoding="utf-8"))
    except Exception:
        return {}


def save_state(d: dict) -> None:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    json.dump(d, open(tmp, "w", encoding="utf-8"))
    os.replace(tmp, STATE)


def message_for(tier: int, expiry: datetime, hours_left: float) -> str:
    when = expiry.astimezone().strftime("%a %d %b %H:%M %Z")
    left = fmt_left(hours_left)
    if tier == TIER_EXPIRED:
        return (
            "🔴 *Claude login session EXPIRED.*\n"
            f"The refresh token lapsed ({when}). I can't reach the API until you "
            "re-authenticate — run `/login` in the bot terminal (or `! claude /login`)."
        )
    if tier == TIER_URGENT:
        return (
            "🟠 *Claude login session expires soon.*\n"
            f"~{left} left (dies {when}). Re-run `/login` when convenient — after it "
            "lapses the bot goes dark until you re-authenticate."
        )
    return (
        "🟡 *Claude login session nearing expiry.*\n"
        f"~{left} left (dies {when}). No action needed yet — heads-up so a `/login` "
        "doesn't catch you by surprise. I'll ping again closer to the deadline."
    )


def send_tg(text: str, dry: bool) -> bool:
    if dry:
        print("[DRY-RUN] would TG-send:\n" + text)
        return True
    py = sys.executable
    try:
        r = subprocess.run([py, TG_SEND, text], capture_output=True, text=True,
                           timeout=30, env={**os.environ, "PYTHONIOENCODING": "utf-8"})
        if r.returncode != 0:
            _log(f"tg_send failed rc={r.returncode} {r.stderr[:200]}")
        return r.returncode == 0
    except Exception as e:
        _log(f"tg_send exception: {e}")
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--probe-only", action="store_true",
                    help="report expiry + tier + state, send nothing, stamp nothing")
    ap.add_argument("--warn-days", type=int, default=3,
                    help="first (yellow) warning when the session has <= N days left (default 3)")
    ap.add_argument("--creds", default=CREDS, help="path to Claude .credentials.json")
    args = ap.parse_args()

    expiry = read_refresh_expiry(args.creds)
    now = datetime.now(timezone.utc)
    state = load_state()

    if expiry is None:
        if args.probe_only:
            print(json.dumps({"error": "no refreshTokenExpiresAt", "creds": args.creds}))
        else:
            _log(f"no refreshTokenExpiresAt in {args.creds} (fail-open, no alert)")
        return 0

    hours_left = (expiry - now).total_seconds() / 3600.0
    tier = tier_for(hours_left, args.warn_days)
    expiry_sig = expiry.isoformat()

    # A changed expiry = session was refreshed/re-logged => reset the ladder.
    if state.get("expiry_sig") != expiry_sig:
        state = {"expiry_sig": expiry_sig, "last_tier": TIER_OK}

    if args.probe_only:
        print(json.dumps({
            "expiry": expiry_sig,
            "hours_left": round(hours_left, 1),
            "tier": TIER_NAME[tier],
            "last_alerted_tier": TIER_NAME.get(state.get("last_tier", TIER_OK), "ok"),
            "creds": args.creds,
        }))
        return 0

    # Only alert on an UPWARD tier crossing (never repeat a tier; never step down).
    if tier <= state.get("last_tier", TIER_OK) or tier == TIER_OK:
        return 0

    if send_tg(message_for(tier, expiry, hours_left), args.dry_run):
        if not args.dry_run:
            state["last_tier"] = tier
            state["last_alerted_at"] = now.isoformat()
            try:
                save_state(state)
            except Exception as e:
                _log(f"state save failed: {e}")
        _log(f"alerted tier={TIER_NAME[tier]} ({fmt_left(hours_left)} left)"
             + (" (dry-run, state not stamped)" if args.dry_run else ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # STRICTLY FAIL-OPEN
        _log(f"fatal (fail-open): {e}")
        sys.exit(0)
