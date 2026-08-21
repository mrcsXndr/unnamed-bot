#!/usr/bin/env python3
"""Tests for health_sweep.py's two survival properties.

Not pytest. Run directly:
  python tools/v2/test_health_sweep.py

The individual checks are not tested here — they read the live box, and a test
that stubs all of them tests nothing. What IS tested is the part that decides
whether this tool is worth having at all, and both halves were learned the hard
way on the original:

  * A TIMEOUT MUST NOT LOOK LIKE A CRASH. A check whose budget sat below the
    median runtime of the thing it measured reported "monitor unreadable
    (exit=-1)" on every single run for weeks. It read as a broken tool rather
    than a wrong budget, which is precisely why nobody fixed it, and a line
    that is always red teaches you to skim past the one line that matters.

  * ONE BROKEN CHECK MUST NOT TAKE THE SWEEP DOWN. The whole value here is a
    single pass over everything; a sweep that dies on its third of six checks
    silently stops reporting on the other three, and the output still looks
    like a report.
"""
from __future__ import annotations

import io
import json
import sys
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import health_sweep as hs  # noqa: E402

FAILED = []


def check(name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  -- {detail}" if detail and not cond else ""))
    if not cond:
        FAILED.append(name)


def sweep_json(checks):
    """Run main() with CHECKS swapped out, and give back the parsed report."""
    original, argv = hs.CHECKS, sys.argv
    hs.CHECKS, sys.argv = checks, ["health_sweep.py", "--json"]
    try:
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = hs.main()
        return rc, json.loads(buf.getvalue())
    finally:
        hs.CHECKS, sys.argv = original, argv


print("timeout is distinguishable from a crash")

rc, out = hs.run([sys.executable, "-c", "import time; time.sleep(5)"], timeout=1)
check("a slow command returns TIMED_OUT, not the -1 catch-all", rc == hs.TIMED_OUT, f"got {rc}")
check("the message names the budget, so the fix is obvious", "exceeded 1s" in out, out[:80])

rc, out = hs.run(["a-command-that-does-not-exist-anywhere"], timeout=10)
check("a genuinely broken command still returns -1", rc == -1, f"got {rc}")
check("...and the two codes are different", hs.TIMED_OUT != -1)

rc, out = hs.run([sys.executable, "-c", "print('hello')"], timeout=30)
check("a normal command is untouched", rc == 0 and "hello" in out, f"rc={rc} out={out[:40]}")


print("\none broken check never takes the sweep down")


def boom():
    raise RuntimeError("upstream went away")


rc, out = sweep_json([
    ("first", lambda: (True, "fine")),
    ("explodes", boom),
    ("last", lambda: (True, "also fine")),
])
names = [r["check"] for r in out["results"]]
check("every check still reported", names == ["first", "explodes", "last"], str(names))
check("the checks AFTER the crash still ran", out["results"][2]["ok"] is True)
check("the crash is a FAIL, not a silent pass", out["results"][1]["ok"] is False)
check("the exception reaches the operator", "upstream went away" in out["results"][1]["detail"],
      out["results"][1]["detail"])
check("the sweep is not ok overall", out["ok"] is False)

# A report tool, not a gate. If this ever exits non-zero it will be wired into
# something as a gate and then start blocking on a disk-space warning.
check("exit code is 0 even when checks fail", rc == 0, f"got {rc}")

rc, out = sweep_json([("fine", lambda: (True, "ok"))])
check("all-green reports ok", out["ok"] is True and rc == 0)

print("\n" + ("all checks passed" if not FAILED else f"{len(FAILED)} FAILED: {', '.join(FAILED)}"))
sys.exit(1 if FAILED else 0)
