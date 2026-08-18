#!/usr/bin/env python3
"""Tests for the quota-warning logic in usage_probe.py.

Not pytest. Run directly:
  python tools/v2/test_usage_probe.py

The network probe isn't tested here (it's a live API call). What IS tested is
the part that can silently rot: WHEN we warn. Two opposite failures both matter
and they pull against each other —

  * warning every tick at 85% is nagging, and an alert that repeats while
    nothing changed trains the operator to ignore the channel;
  * a dedupe key that repeats is a permanent mute button — keying on the reset
    TEXT rather than the reset INSTANT silently swallows the next block, because
    the same wall-clock reset recurs daily.

So the load-bearing case is #5: a NEW window at the same utilization must warn
again. Everything else guards the quiet side.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import usage_probe as up  # noqa: E402

FAILED = []


def check(name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  -- {detail}" if detail and not cond else ""))
    if not cond:
        FAILED.append(name)


def state(util_5h, reset_5h, util_7d=0.10, reset_7d=None):
    return {
        "five_h": {"utilization": util_5h, "reset": reset_5h},
        "seven_d": {"utilization": util_7d, "reset": reset_7d or (time.time() + 86400)},
        "overage": "rejected",
    }


def main() -> int:
    soon = time.time() + 3600
    print("threshold warnings")

    # 1. Quiet below the first threshold.
    s = state(0.42, soon)
    check("no warning at 42%", up._warn(s, {}) is None)

    # 2. First crossing speaks.
    s = state(0.83, soon)
    msg = up._warn(s, {})
    check("warns on crossing 80%", msg is not None and "5-hour" in msg)
    check("warning carries the numbers", msg is not None and "83%" in msg, msg)
    check("warning names the hard-stop consequence",
          msg is not None and "hard stop" in msg, msg)
    after_80 = {"alerted": s["alerted"]}

    # 3. Same window, still high, drifted up but under the next threshold: quiet.
    s2 = state(0.88, soon)
    check("silent while sitting in the same band", up._warn(s2, after_80) is None)

    # 4. Next threshold in the same window does speak.
    s3 = state(0.91, soon)
    msg3 = up._warn(s3, after_80)
    check("warns again on crossing 90%", msg3 is not None)
    after_90 = {"alerted": s3["alerted"]}
    check("silent at 92% after the 90% warning",
          up._warn(state(0.92, soon), after_90) is None)

    # 5. THE REGRESSION: a new window is a new conversation.
    later = soon + 5 * 3600
    msg5 = up._warn(state(0.83, later), after_90)
    check("warns again in the NEXT window at the same level", msg5 is not None,
          "a reset-keyed dedupe that never expires is a permanent mute")

    # 6. Bookkeeping for expired windows is dropped, not accumulated forever.
    stale = {"alerted": {f"five_h:{int(time.time()) - 99999}": 0.9}}
    s6 = state(0.42, soon)
    up._warn(s6, stale)
    check("prunes windows that already reset", s6["alerted"] == {}, str(s6["alerted"]))

    # 7. Either window can trigger independently.
    msg7 = up._warn(state(0.10, soon, util_7d=0.95), {})
    check("weekly window warns on its own", msg7 is not None and "weekly" in msg7, msg7)

    # 8. Missing headers must not crash or invent a warning.
    check("absent utilization is not a crossing",
          up._warn({"five_h": {"utilization": None, "reset": soon},
                    "seven_d": {}}, {}) is None)

    print("\nformatting")
    # The contract is an exact percentage AND an absolute reset timestamp: a
    # relative "in 2h26m" is meaningless in a message read an hour later, so the
    # stamp is part of the contract, not decoration.
    summary = up.summarize(state(0.07, soon))
    check("summary is one line", "\n" not in summary, summary)
    check("summary leads with the exact percentage", summary.startswith("5h 7%"), summary)
    import re as _re
    check("summary carries an absolute reset date AND time",
          bool(_re.search(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}", summary)), summary)
    check("percentage keeps sub-integer precision",
          "33.5%" in up.summarize(state(0.335, soon)), up.summarize(state(0.335, soon)))
    check("empty state renders as nothing", up.summarize({}) == "")
    check("unknown utilization renders as ?", up._pct(None) == "?")
    check("non-allowed status is surfaced",
          "!rejected" in up.summarize({**state(0.5, soon), "status": "rejected"}))

    print("\nblock recording (feeds the auto-resume)")
    import json
    import tempfile

    def with_temp_state(fn):
        d = tempfile.mkdtemp()
        orig = up.LIMIT_STATE_PATH
        up.LIMIT_STATE_PATH = Path(d) / "usage_limit_state.json"
        try:
            return fn(up.LIMIT_STATE_PATH)
        finally:
            up.LIMIT_STATE_PATH = orig

    # Healthy account: the file must not be created at all. A quota probe that
    # writes a block record on a good day would trigger a spurious relaunch.
    def healthy(p):
        r = up.record_block({"http": 200, "status": "allowed",
                             "five_h": {"reset": time.time() + 3600, "status": "allowed"},
                             "seven_d": {"reset": time.time() + 86400, "status": "allowed"}})
        return r, p.exists()
    r, existed = with_temp_state(healthy)
    check("healthy probe records nothing", r is None and not existed)

    # 429 with no per-window flag: fall back to the 5h reset.
    def http429(p):
        up.record_block({"http": 429, "status": "allowed",
                         "five_h": {"reset": time.time() + 1800, "status": "allowed"},
                         "seven_d": {"reset": time.time() + 86400, "status": "allowed"}})
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
    st = with_temp_state(http429)
    check("a 429 records blocked_until", bool(st.get("blocked_until")), str(st))
    check("records its source", st.get("source") == "usage_probe")
    check("clears any prior resume marker", "resume_skipped" not in st)

    # Both windows blocked: wait for the LATER one, or we resume into the other.
    def both(p):
        later = time.time() + 86400
        up.record_block({"http": 429, "status": "rejected",
                         "five_h": {"reset": time.time() + 600, "status": "rejected"},
                         "seven_d": {"reset": later, "status": "rejected"}})
        return json.loads(p.read_text(encoding="utf-8")), later
    st, later = with_temp_state(both)
    from datetime import datetime
    got = datetime.fromisoformat(st["blocked_until"]).timestamp()
    check("waits for the LAST window to clear", abs(got - later) < 2,
          f"blocked_until={st['blocked_until']} expected ~{later}")

    # Same block seen twice must not re-arm (the supervisor probes every tick).
    def twice(p):
        payload = {"http": 429, "status": "rejected",
                   "five_h": {"reset": time.time() + 1800, "status": "rejected"},
                   "seven_d": {"reset": time.time() + 86400, "status": "allowed"}}
        first = up.record_block(payload)
        second = up.record_block(payload)
        return first, second
    first, second = with_temp_state(twice)
    check("re-recording the same block is a no-op", first is not None and second is None)

    # A reset already in the past is not something to wait for.
    def past(p):
        r = up.record_block({"http": 429, "status": "rejected",
                             "five_h": {"reset": time.time() - 60, "status": "rejected"},
                             "seven_d": {}})
        return r, p.exists()
    r, existed = with_temp_state(past)
    check("a past reset records nothing", r is None and not existed)

    print()
    if FAILED:
        print(f"{len(FAILED)} FAILED: {', '.join(FAILED)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
