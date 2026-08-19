#!/usr/bin/env python3
"""A card the bot moves itself must not alert the operator.

Not pytest. Run directly:
  python tools/v2/test_board_self_move.py

If a supervisor polls the board each tick and alerts on every card that entered
the queue column, that is correct for a card the operator drags on their phone
and pure noise for one the bot just moved — a run of self-inflicted pings reads
as spam. `snapshot_ack` records the bot's own move in the poll snapshot so the
next poll sees nothing new. It must stay NARROW: a move the operator made in the
meantime still has to alert.

Runs on a temp snapshot; never touches memory/tasks/ or a live board.
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_projects as g  # noqa: E402

FAILED = []


def check(name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  -- {detail}" if detail and not cond else ""))
    if not cond:
        FAILED.append(name)


def classify(prev_rows, cur_rows):
    """The exact kind[] poll() would emit for these two states."""
    prev = {x["id"]: x for x in prev_rows}
    out = []
    for i in cur_rows:
        o = prev.get(i["id"])
        if not o:
            out.append("added")
        elif o.get("status") != i.get("status"):
            out.append("queued" if (i.get("status") or "").lower() in ("ready", "do asap", "asap") else "moved")
    return out


CARD = {"id": "PVTI_test", "title": "a card", "status": "Backlog"}
LIVE = [{**CARD, "status": "Ready"}]


def main() -> int:
    real_snap = g.SNAP_PATH
    g.SNAP_PATH = Path(tempfile.mkdtemp()) / "gh_project.snapshot.json"
    assert g.SNAP_PATH != real_snap
    real_before = real_snap.read_bytes() if real_snap.exists() else None

    print("self-move suppression")

    # Baseline: without the ack, this is exactly the alert the operator gets.
    check("un-acked move WOULD alert", classify([CARD], LIVE) == ["queued"])

    # With the ack, the snapshot already knows, so the poll sees nothing.
    g.SNAP_PATH.write_text(json.dumps([dict(CARD)]), encoding="utf-8")
    g.snapshot_ack("PVTI_test", "Ready")
    snap = json.loads(g.SNAP_PATH.read_text(encoding="utf-8"))
    check("ack records the new status", snap[0]["status"] == "Ready", str(snap))
    check("acked move is silent", classify(snap, LIVE) == [])

    # A move the OPERATOR makes must still alert — the ack is narrow on purpose.
    other_live = [{**CARD, "status": "Ready"},
                  {"id": "PVTI_theirs", "title": "their card", "status": "Ready"}]
    snap_with_theirs = snap + [{"id": "PVTI_theirs", "title": "their card", "status": "Backlog"}]
    check("someone else's move still alerts",
          classify(snap_with_theirs, other_live) == ["queued"])

    # Unknown item: leave the snapshot alone rather than inventing a row.
    before = g.SNAP_PATH.read_text(encoding="utf-8")
    g.snapshot_ack("PVTI_not_in_snapshot", "Ready")
    check("unknown id does not mutate the snapshot",
          g.SNAP_PATH.read_text(encoding="utf-8") == before)

    # Missing snapshot must not raise — board writes come first.
    g.SNAP_PATH.unlink()
    try:
        g.snapshot_ack("PVTI_test", "Ready")
        check("no snapshot is a safe no-op", True)
    except Exception as e:
        check("no snapshot is a safe no-op", False, str(e))

    real_after = real_snap.read_bytes() if real_snap.exists() else None
    check("the live snapshot was never written", real_before == real_after)

    print()
    if FAILED:
        print(f"{len(FAILED)} FAILED: {', '.join(FAILED)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
