#!/usr/bin/env python3
"""Live Claude subscription quota, read from the API instead of guessed.

WHY THIS EXISTS
---------------
Detecting a usage limit from the transcript banner is REACTIVE: by the time the
banner exists the session is already dark, and nothing ever said "you are at 90%
with an hour of work queued".

Anthropic returns the account's unified rate-limit state as response headers on
every inference call, so a ~10-token Haiku request buys the real numbers:

    anthropic-ratelimit-unified-status: allowed
    anthropic-ratelimit-unified-5h-utilization: 0.07     <- 7% of the 5h window
    anthropic-ratelimit-unified-5h-reset: 1787062200
    anthropic-ratelimit-unified-7d-utilization: 0.33     <- 33% of the week
    anthropic-ratelimit-unified-7d-reset: 1787137200
    anthropic-ratelimit-unified-overage-status: rejected

(`/api/oauth/usage` also exists and is what the interactive `/usage` command
calls, but it needs a `user:profile`-scoped token. The stored setup-token is
inference-only and 403s on it — verified 2026-08-18. Headers need no extra
scope, so they are the portable signal.)

COST: one Haiku call, 8 input + 1 output tokens. Negligible against the very
budget it measures — but not free, which is why `status` reads the cache and
only `probe` hits the network.

COMMANDS
    probe   [--warn] [--json]   call the API, write the cache, optionally TG-warn
    status  [--json] [--max-age SEC]   print from cache (never calls the API)

STRICTLY FAIL-OPEN. A quota probe must never be the reason something breaks:
every path swallows its own errors and exits 0, and `status` prints nothing
rather than a stale guess.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
STATE_PATH = REPO_ROOT / "memory" / "metrics" / "usage_state.json"

API_URL = "https://api.anthropic.com/v1/messages"
# Cheapest model that still exercises the account's unified limit.
PROBE_MODEL = "claude-haiku-4-5-20251001"

# Warn once per threshold per window. Crossing 80 then 90 sends two messages;
# sitting at 85% for three hours sends none. An alert that repeats while nothing
# has changed trains the operator to ignore the channel.
THRESHOLDS = (0.80, 0.90, 0.97)


def _token() -> str | None:
    """OAuth token: env first (how the harness passes it), then the setup-token."""
    tok = (os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") or "").strip()
    if tok:
        return tok
    try:
        return (Path.home() / ".claude" / ".oauth_token").read_text(encoding="utf-8").strip() or None
    except Exception:
        return None


def _load_state() -> dict:
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save_state(state: dict) -> None:
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        tmp.replace(STATE_PATH)  # atomic; the statusline reads this on every render
    except Exception:
        pass


def probe() -> dict | None:
    """One minimal call; return the parsed rate-limit headers, or None."""
    tok = _token()
    if not tok:
        return None
    body = json.dumps({
        "model": PROBE_MODEL,
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "."}],
    }).encode()
    req = urllib.request.Request(API_URL, data=body, method="POST", headers={
        "Authorization": f"Bearer {tok}",
        "anthropic-beta": "oauth-2025-04-20",
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            headers = r.headers
        http_code = 200
    except urllib.error.HTTPError as e:
        # A 429 is not a failure to read — it IS the answer, and its headers
        # carry the reset we most want. Anything else, give up quietly.
        if e.code != 429:
            return None
        headers, http_code = e.headers, 429
    except Exception:
        return None

    def num(name):
        try:
            return float(headers.get(f"anthropic-ratelimit-unified-{name}"))
        except (TypeError, ValueError):
            return None

    return {
        "ts": int(time.time()),
        "http": http_code,
        "status": headers.get("anthropic-ratelimit-unified-status"),
        "five_h": {
            "utilization": num("5h-utilization"),
            "reset": num("5h-reset"),
            "status": headers.get("anthropic-ratelimit-unified-5h-status"),
        },
        "seven_d": {
            "utilization": num("7d-utilization"),
            "reset": num("7d-reset"),
            "status": headers.get("anthropic-ratelimit-unified-7d-status"),
        },
        # 'rejected' means the org has overage off, so hitting the cap is a HARD
        # stop rather than a spend-more-and-continue. Worth saying out loud in a
        # warning, since it changes what the operator can do about it.
        "overage": headers.get("anthropic-ratelimit-unified-overage-status"),
    }


LIMIT_STATE_PATH = REPO_ROOT / "memory" / "metrics" / "usage_limit_state.json"


def record_block(cur: dict) -> str | None:
    """If the API says we're limited, record an exact reset time.

    Writes `blocked_until` to memory/metrics/usage_limit_state.json for whatever
    auto-resume the bot runs. The alternative source is the transcript banner,
    which depends on CC having written the transcript AND on a regex matching a
    human string like "9:50pm (Europe/Stockholm)". The API gives a unix
    timestamp with no parsing at all, so a block observed here still produces a
    resume if the banner is never seen or its wording changes.

    Writes ONLY when actually blocked and the reset is in the future. Never
    touches the file otherwise, so it cannot disturb a window the monitor is
    already tracking.
    """
    blocked = cur.get("http") == 429 or (cur.get("status") or "allowed") != "allowed"
    if not blocked:
        return None
    # Wait for the LAST window to clear: if both the 5h and the weekly are
    # blocked, resuming when the 5h resets just walks back into the weekly.
    windows = [cur.get("five_h") or {}, cur.get("seven_d") or {}]
    resets = [w["reset"] for w in windows
              if w.get("reset") and w.get("status") not in ("allowed", None)]
    if not resets:
        # 429 without a per-window flag: fall back to the 5h reset.
        resets = [w["reset"] for w in windows[:1] if w.get("reset")]
    reset = max(resets) if resets else None
    if not reset or reset <= time.time():
        return None  # nothing credible to wait for

    from datetime import datetime, timezone
    until = datetime.fromtimestamp(reset, timezone.utc).astimezone()
    # Window id keyed on the reset INSTANT. A key built from the reset TEXT is
    # not unique — the same wall-clock reset recurs daily, so deduping on it
    # silently swallows the next block.
    wid = f"probe|{int(reset)}"
    try:
        state = json.loads(LIMIT_STATE_PATH.read_text(encoding="utf-8"))
    except Exception:
        state = {}
    if state.get("last_alerted_window") == wid:
        return None  # this block is already recorded
    state.update({
        "last_alerted_reset": until.strftime("%H:%M (%Z)"),
        "last_alerted_window": wid,
        "last_alerted_at": datetime.now(timezone.utc).astimezone().isoformat(),
        "blocked_until": until.isoformat(),
        "source": "usage_probe",
    })
    state.pop("resumed_for", None)
    state.pop("resume_skipped", None)
    try:
        LIMIT_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = LIMIT_STATE_PATH.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(state, indent=1) + "\n", encoding="utf-8")
        tmp.replace(LIMIT_STATE_PATH)
    except Exception:
        return None
    return until.isoformat()


def _pct(u) -> str:
    """Exact, not rounded to something friendlier. The header carries two
    decimals of a fraction, so 0.335 is 33.5%; rounding to '34%' throws away
    precision the operator asked for."""
    if u is None:
        return "?"
    v = u * 100
    return f"{v:.0f}%" if abs(v - round(v)) < 0.05 else f"{v:.1f}%"


def _stamp(reset) -> str:
    """Absolute local date + time. A relative '2h26m' is meaningless in a
    message read an hour later, so the timestamp leads."""
    if not reset:
        return "?"
    from datetime import datetime
    return datetime.fromtimestamp(reset).astimezone().strftime("%Y-%m-%d %H:%M")


def _mins_to(reset) -> str:
    if not reset:
        return "?"
    m = int((reset - time.time()) / 60)
    if m <= 0:
        return "now"
    return f"{m}m" if m < 90 else f"{m // 60}h{m % 60:02d}m"


def summarize(s: dict) -> str:
    """One line: `5h 7% -> resets 2026-08-18 16:10 (2h26m) · 7d 33% -> ...`."""
    if not s:
        return ""
    f, d = s.get("five_h") or {}, s.get("seven_d") or {}
    parts = [
        f"5h {_pct(f.get('utilization'))} -> resets {_stamp(f.get('reset'))} ({_mins_to(f.get('reset'))})",
        f"7d {_pct(d.get('utilization'))} -> resets {_stamp(d.get('reset'))} ({_mins_to(d.get('reset'))})",
    ]
    if s.get("status") and s["status"] != "allowed":
        parts.append(f"!{s['status']}")
    return " · ".join(parts)


def _tg(text: str) -> None:
    try:
        subprocess.run(
            [sys.executable, str(REPO_ROOT / "tools" / "tg" / "tg_send.py"), text],
            cwd=str(REPO_ROOT), timeout=60, capture_output=True,
            env={**os.environ, "PYTHONIOENCODING": "utf-8"},
        )
    except Exception:
        pass


def _warn(new: dict, prev: dict) -> str | None:
    """Highest threshold newly crossed in either window, keyed by reset stamp.

    Keying on the RESET timestamp is what makes this fire again next window
    instead of muting forever. A key that repeats across windows is a permanent
    mute button.
    """
    alerted = dict(prev.get("alerted") or {})
    fired = []
    for key, label in (("five_h", "5-hour"), ("seven_d", "weekly")):
        cur = new.get(key) or {}
        util, reset = cur.get("utilization"), cur.get("reset")
        if util is None or not reset:
            continue
        window = f"{key}:{int(reset)}"
        already = alerted.get(window, 0.0)
        crossed = [t for t in THRESHOLDS if util >= t > already]
        if crossed:
            alerted[window] = max(crossed)
            fired.append((label, util, reset))
    # Drop bookkeeping for windows that have already reset.
    now = time.time()
    alerted = {k: v for k, v in alerted.items() if float(k.split(":")[1]) > now - 3600}
    new["alerted"] = alerted
    if not fired:
        return None
    lines = [f"⚠️ **Claude quota** — {', '.join(l for l, _, _ in fired)} window crossing a threshold."]
    lines.append("")
    lines.append(summarize(new))
    if new.get("overage") == "rejected":
        lines.append("")
        lines.append("Overage is disabled on the org, so hitting the cap is a hard stop, not extra spend. "
                     "I'll auto-resume when it resets, but anything queued stalls until then.")
    return "\n".join(lines)


def main(argv) -> int:
    cmd = argv[1].lower() if len(argv) > 1 else "status"
    as_json = "--json" in argv

    if cmd == "probe":
        prev = _load_state()
        # Rate-limit the rate-limit check. The supervisor ticks every 3 minutes
        # and shouldn't turn a quota probe into its own traffic; a caller that
        # genuinely needs fresh numbers (a TG /usage) passes --force.
        min_interval = 300
        if "--min-interval" in argv:
            try:
                min_interval = int(argv[argv.index("--min-interval") + 1])
            except (IndexError, ValueError):
                pass
        if "--force" not in argv and prev and time.time() - prev.get("ts", 0) < min_interval:
            print(json.dumps(prev, indent=2) if as_json else summarize(prev))
            return 0
        cur = probe()
        if not cur:
            if as_json:
                print(json.dumps({"error": "probe failed"}))
            else:
                print("usage probe: unavailable")
            return 0  # fail-open: never a non-zero from a quota check
        msg = _warn(cur, prev) if "--warn" in argv else None
        cur.setdefault("alerted", prev.get("alerted") or {})
        _save_state(cur)
        # If we're already blocked, hand the resume path an exact reset time.
        blocked_until = record_block(cur)
        if blocked_until and "--warn" in argv:
            msg = (f"🚫 **Claude limit reached.** Blocked until {blocked_until[11:16]}.\n\n"
                   f"{summarize(cur)}\n\nRecorded the window — I'll relaunch myself once it lifts.")
        if msg:
            _tg(msg)
        print(json.dumps(cur, indent=2) if as_json else summarize(cur))
        return 0

    if cmd == "status":
        s = _load_state()
        max_age = 0
        if "--max-age" in argv:
            try:
                max_age = int(argv[argv.index("--max-age") + 1])
            except (IndexError, ValueError):
                max_age = 0
        # Silence beats a stale number: the whole point is knowing where we
        # actually are, and a 6-hour-old 40% could be a current 100%.
        if max_age and s and time.time() - s.get("ts", 0) > max_age:
            s = {}
        print(json.dumps(s) if as_json else summarize(s))
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # fail-open, always
        print(f"usage_probe: {e}", file=sys.stderr)
        sys.exit(0)
