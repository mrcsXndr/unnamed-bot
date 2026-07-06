#!/usr/bin/env python3
"""Commitments loop — due-dated follow-ups that resurface automatically.

A *commitment* is a due-dated follow-up ("check back on X by <when>") that the
bot should resurface on its own instead of relying on the operator re-asking.
(Fable rec #2.)

Storage
-------
A single, session-independent JSON store at `memory/commitments.json` (a JSON
array). Writes go through tools/v2/safe_write.safe_replace so a concurrent
add/done can't clobber the file.

Schema (per commitment)
-----------------------
{
  "id": "c-<utc-compact>-<short>",   # stable unique id
  "created_ts": "<ISO8601 UTC>",
  "due_ts": "<ISO8601 UTC>" | null,
  "text": "<the follow-up>",
  "status": "open" | "done",
  "source_session": "<session id or null>",
  "last_surfaced_ts": "<ISO8601 UTC>"   # optional: heartbeat cooldown stamp
}

CLI
---
  commitments.py add "<text>" [--due <ISO | Nd|Nh|Nm | tomorrow>]
  commitments.py list [--open] [--due-before <ISO|now>]
  commitments.py done <id>
  commitments.py surface
  commitments.py heartbeat [--dry-run]

`surface` prints a short markdown block of OPEN commitments that are due now or
overdue, OR have no due date but are older than 24h. Prints nothing + exits 0
when there is nothing to surface — this is what the SessionStart hook calls.

`heartbeat` is the proactive tick (called by scripts/supervisor.ps1 every
~3 min): same due-selection as `surface`, minus items alerted within the
cooldown window (BOT_HEARTBEAT_COOLDOWN_H, default 6h). If any remain it sends
ONE Telegram message via tools/tg/tg_send.py (status footer kept — never
--no-status) and stamps each item's `last_surfaced_ts` so the same commitment
isn't re-alerted every tick. Silent + exit 0 when nothing is due. `--dry-run`
prints the message instead of sending but STILL stamps the cooldown (full path
minus the network — keeps the cooldown testable). On a failed real send,
nothing is stamped, so the next tick retries.

Stdlib only (json, datetime, argparse). datetime.now() is fine here: this is a
standalone store, not a deterministic workflow script.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from safe_write import safe_replace  # noqa: E402  atomic+locked write substrate

REPO_ROOT = Path(__file__).resolve().parents[2]
STORE_PATH = REPO_ROOT / "memory" / "commitments.json"
CURRENT_SESSION_FILE = REPO_ROOT / ".claude" / ".current_session_id"
JOURNAL_PY = Path(__file__).resolve().parent / "journal.py"
TG_SEND_PY = REPO_ROOT / "tools" / "tg" / "tg_send.py"

NO_DUE_STALE_HOURS = 24
DEFAULT_COOLDOWN_H = 6.0  # heartbeat re-alert window; override BOT_HEARTBEAT_COOLDOWN_H


# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s: str) -> datetime | None:
    """Parse an ISO8601 string into an aware UTC datetime. Returns None on
    failure. Accepts a trailing 'Z' and naive strings (assumed UTC)."""
    if not s:
        return None
    txt = s.strip()
    if txt.endswith("Z"):
        txt = txt[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(txt)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


_REL_RE = re.compile(r"^(\d+)\s*([dhm])$", re.I)


def parse_due(raw: str | None) -> tuple[str | None, str | None]:
    """Parse a lenient --due value into (iso_or_none, warning_or_none).

    - None/empty            -> (None, None)
    - valid ISO8601         -> passes through (normalised to UTC)
    - 'Nd' / 'Nh' / 'Nm'    -> now + offset (days/hours/minutes)
    - 'tomorrow'            -> now + 1 day at 09:00 (UTC)
    - unparseable           -> (None, "<warning>")
    """
    if raw is None:
        return None, None
    txt = raw.strip()
    if not txt:
        return None, None

    low = txt.lower()
    if low == "tomorrow":
        tomorrow = (_now() + timedelta(days=1)).replace(
            hour=9, minute=0, second=0, microsecond=0
        )
        return _iso(tomorrow), None

    m = _REL_RE.match(txt)
    if m:
        n = int(m.group(1))
        unit = m.group(2).lower()
        delta = {"d": timedelta(days=n), "h": timedelta(hours=n), "m": timedelta(minutes=n)}[unit]
        return _iso(_now() + delta), None

    iso = _parse_iso(txt)
    if iso is not None:
        return _iso(iso), None

    return None, f"could not parse --due '{raw}'; stored with no due date"


# ---------------------------------------------------------------------------
# Store I/O
# ---------------------------------------------------------------------------

def _load() -> list[dict]:
    try:
        txt = STORE_PATH.read_text(encoding="utf-8")
    except OSError:
        return []
    if not txt.strip():
        return []
    try:
        data = json.loads(txt)
    except json.JSONDecodeError:
        return []
    return data if isinstance(data, list) else []


def _dump(items: list[dict]) -> str:
    return json.dumps(items, indent=2, ensure_ascii=False) + "\n"


def _resolve_session() -> str | None:
    try:
        sid = CURRENT_SESSION_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return sid or None


def _journal_note(session: str | None, text: str) -> None:
    """Best-effort: append an `action` journal entry. Fail-open — any error
    (no session, journal.py missing, write fails) is swallowed."""
    if not session:
        return
    try:
        import subprocess
        subprocess.run(
            [sys.executable, str(JOURNAL_PY), "append", session, "action", text],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_add(text: str, due: str | None) -> int:
    due_iso, warning = parse_due(due)
    if warning:
        print(f"WARNING: {warning}", file=sys.stderr)

    session = _resolve_session()
    new_id = f"c-{_now().strftime('%Y%m%dT%H%M%S')}-{uuid.uuid4().hex[:6]}"
    item = {
        "id": new_id,
        "created_ts": _iso(_now()),
        "due_ts": due_iso,
        "text": text.strip(),
        "status": "open",
        "source_session": session,
    }

    def _transform(current: str) -> str:
        try:
            items = json.loads(current) if current.strip() else []
            if not isinstance(items, list):
                items = []
        except json.JSONDecodeError:
            items = []
        items.append(item)
        return _dump(items)

    result = safe_replace(STORE_PATH, _transform, create=True)
    if result.get("status") not in ("written", "noop"):
        print(f"ERROR: write failed ({result.get('status')})", file=sys.stderr)
        return 1

    due_part = f" (due {due_iso})" if due_iso else ""
    _journal_note(session, f"commitment created: {item['text']}{due_part} [{new_id}]")
    print(new_id)
    return 0


def cmd_list(only_open: bool, due_before: str | None) -> int:
    items = _load()
    if only_open:
        items = [c for c in items if c.get("status") == "open"]

    if due_before is not None:
        cutoff = _now() if due_before.strip().lower() == "now" else _parse_iso(due_before)
        if cutoff is None:
            print(f"ERROR: bad --due-before '{due_before}'", file=sys.stderr)
            return 2
        filtered = []
        for c in items:
            d = _parse_iso(c.get("due_ts") or "")
            if d is not None and d <= cutoff:
                filtered.append(c)
        items = filtered

    print(json.dumps(items, indent=2, ensure_ascii=False))
    return 0


def cmd_done(commitment_id: str) -> int:
    found = {"hit": False}

    def _transform(current: str) -> str:
        try:
            items = json.loads(current) if current.strip() else []
            if not isinstance(items, list):
                items = []
        except json.JSONDecodeError:
            items = []
        for c in items:
            if c.get("id") == commitment_id:
                c["status"] = "done"
                found["hit"] = True
        return _dump(items)

    result = safe_replace(STORE_PATH, _transform, create=True)
    if not found["hit"]:
        print(f"ERROR: no commitment with id '{commitment_id}'", file=sys.stderr)
        return 1
    if result.get("status") not in ("written", "noop"):
        print(f"ERROR: write failed ({result.get('status')})", file=sys.stderr)
        return 1
    print(f"done: {commitment_id}")
    return 0


def _is_due(c: dict, now: datetime) -> bool:
    """A commitment surfaces when: due_ts is set and <= now (due/overdue), OR
    it has no due date but was created more than NO_DUE_STALE_HOURS ago."""
    due = _parse_iso(c.get("due_ts") or "")
    if due is not None:
        return due <= now
    created = _parse_iso(c.get("created_ts") or "")
    if created is None:
        return False
    return (now - created) >= timedelta(hours=NO_DUE_STALE_HOURS)


def _sort_due(due: list[dict], now: datetime) -> None:
    """Stable order: dated (by due) first, then undated (by created)."""
    def _key(c: dict):
        d = _parse_iso(c.get("due_ts") or "")
        if d is not None:
            return (0, d)
        return (1, _parse_iso(c.get("created_ts") or "") or now)

    due.sort(key=_key)


def _surface_lines(due: list[dict], now: datetime) -> list[str]:
    lines = []
    for c in due:
        due_ts = c.get("due_ts")
        if due_ts:
            tag = f"overdue since {due_ts}" if (_parse_iso(due_ts) or now) < now else f"due {due_ts}"
        else:
            tag = f"no due date, opened {c.get('created_ts')}"
        lines.append(f"- {c.get('text')} ({tag}) [{c.get('id')}]")
    return lines


def cmd_surface() -> int:
    now = _now()
    due = [c for c in _load() if c.get("status") == "open" and _is_due(c, now)]
    if not due:
        return 0
    _sort_due(due, now)
    print("\n".join(_surface_lines(due, now)))
    return 0


# ---------------------------------------------------------------------------
# Heartbeat (proactive tick — supervisor calls this every ~3 min)
# ---------------------------------------------------------------------------

def _cooldown() -> timedelta:
    try:
        hours = float(os.environ.get("BOT_HEARTBEAT_COOLDOWN_H", "") or DEFAULT_COOLDOWN_H)
    except ValueError:
        hours = DEFAULT_COOLDOWN_H
    return timedelta(hours=hours)


def _autonomous_hook(due_items: list[dict]) -> None:
    """AUTONOMOUS-ACTION SEAM (gated, default OFF, does nothing yet).

    Future: when BOT_HEARTBEAT_AUTONOMOUS=1, this is where the heartbeat may
    dispatch actual work on due commitments (e.g. queue a Director task)
    instead of only notifying. Today the gate is recognised but no action is
    wired — heartbeat is notify-only by design (2026-06-11 brief)."""
    if os.environ.get("BOT_HEARTBEAT_AUTONOMOUS", "0") != "1":
        return
    print(
        f"[heartbeat] BOT_HEARTBEAT_AUTONOMOUS=1 but no action is wired yet "
        f"({len(due_items)} due item(s)) — notify-only.",
        file=sys.stderr,
    )


def _send_tg(message: str) -> bool:
    """Send via tools/tg/tg_send.py (direct Bot API; status footer auto-appended —
    never pass --no-status). Returns True on exit 0."""
    import subprocess
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    try:
        r = subprocess.run(
            [sys.executable, str(TG_SEND_PY), message],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            timeout=60, env=env,
        )
    except Exception as e:
        print(f"ERROR: tg_send failed: {e!r}", file=sys.stderr)
        return False
    if r.returncode != 0:
        err = (r.stderr or b"").decode("utf-8", errors="replace").strip()
        print(f"ERROR: tg_send exit {r.returncode}: {err[:300]}", file=sys.stderr)
        return False
    return True


def cmd_heartbeat(dry_run: bool) -> int:
    now = _now()
    cooldown = _cooldown()
    fresh = []
    for c in _load():
        if c.get("status") != "open" or not _is_due(c, now):
            continue
        last = _parse_iso(c.get("last_surfaced_ts") or "")
        if last is not None and (now - last) < cooldown:
            continue  # already alerted within the cooldown window
        fresh.append(c)
    if not fresh:
        return 0  # nothing due (or all cooling down) -> send NOTHING

    _sort_due(fresh, now)
    message = "⏰ **Due commitments**\n" + "\n".join(_surface_lines(fresh, now))

    if dry_run:
        print(message)
    elif not _send_tg(message):
        return 1  # send failed -> do NOT stamp, next tick retries

    # Stamp last_surfaced_ts on the alerted items (atomic via safe_write).
    ids = {c.get("id") for c in fresh}
    stamp = _iso(now)

    def _transform(current: str) -> str:
        try:
            items = json.loads(current) if current.strip() else []
            if not isinstance(items, list):
                items = []
        except json.JSONDecodeError:
            items = []
        for c in items:
            if c.get("id") in ids:
                c["last_surfaced_ts"] = stamp
        return _dump(items)

    result = safe_replace(STORE_PATH, _transform, create=True)
    if result.get("status") not in ("written", "noop"):
        print(f"WARNING: cooldown stamp failed ({result.get('status')})", file=sys.stderr)

    _autonomous_hook(fresh)
    tag = " [dry-run]" if dry_run else ""
    print(f"alerted {len(fresh)} commitment(s){tag}: {', '.join(sorted(ids))}")
    return 0


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="commitments", description=__doc__)
    sub = parser.add_subparsers(dest="cmd")

    p_add = sub.add_parser("add", help="add a commitment")
    p_add.add_argument("text")
    p_add.add_argument("--due", default=None, help="ISO, Nd/Nh/Nm, or 'tomorrow'")

    p_list = sub.add_parser("list", help="list commitments")
    p_list.add_argument("--open", dest="only_open", action="store_true")
    p_list.add_argument("--due-before", default=None, help="ISO or 'now'")

    p_done = sub.add_parser("done", help="mark a commitment complete")
    p_done.add_argument("id")

    sub.add_parser("surface", help="print open commitments due now/overdue")

    p_hb = sub.add_parser(
        "heartbeat",
        help="TG-alert due commitments not in cooldown (supervisor tick)")
    p_hb.add_argument("--dry-run", action="store_true",
                      help="print instead of sending (still stamps cooldown)")

    args = parser.parse_args(argv[1:])

    if args.cmd == "add":
        return cmd_add(args.text, args.due)
    if args.cmd == "list":
        return cmd_list(args.only_open, args.due_before)
    if args.cmd == "done":
        return cmd_done(args.id)
    if args.cmd == "surface":
        return cmd_surface()
    if args.cmd == "heartbeat":
        return cmd_heartbeat(args.dry_run)

    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
