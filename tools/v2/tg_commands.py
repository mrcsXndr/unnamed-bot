#!/usr/bin/env python3
"""TG slash-command handler.

When the Director receives a Telegram message that starts with `/cmd`,
this script intercepts it (via the user-prompt-submit hook) and runs
the matching action. Reply is sent via tools/tg/tg_send.py.

Cannot force Claude Code's CLI `/compact` from outside the harness — but
the on-disk Slack-pattern channels (Journal + Timeline) ARE under our
control, so `/compact` here means: distill journal → timeline, summarize,
mark a checkpoint. Next session start picks up the clean state.

Supported commands:
  /status            — system status (cwd, git, ctx, sess, TG)
  /journal [n]       — last N journal entries (default 30)
  /timeline          — current critic timeline (head)
  /compact           — distill journal → timeline + checkpoint marker
  /tasks             — read top items from task board
  /update            — update Claude Code; self-restart the bot if a new version landed
  /help              — list commands

Exit codes:
  0  command handled (caller should block the prompt from main thread)
  1  not a recognised command (caller should let the prompt pass)
  2  command handled but failed (caller still blocks; reply was sent)
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PY_EXE = sys.executable or "python"

KNOWN = {"/status", "/journal", "/timeline", "/compact", "/tasks", "/update", "/help"}


def _send_tg(text: str, reply_to: str | None = None) -> int:
    cmd = [PY_EXE, str(REPO_ROOT / "tools" / "tg" / "tg_send.py"), "--quiet"]
    if reply_to:
        cmd += ["--reply-to", reply_to]
    cmd.append(text)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15, encoding="utf-8")
        return r.returncode
    except Exception as e:
        print(f"tg_send failed: {e}", file=sys.stderr)
        return 2


def _current_session() -> str:
    f = REPO_ROOT / ".claude" / ".current_session_id"
    if f.exists():
        try:
            return f.read_text(encoding="utf-8").strip()
        except Exception:
            pass
    return ""


def cmd_status(args: list[str], reply_to: str | None) -> int:
    r = subprocess.run(
        [PY_EXE, str(REPO_ROOT / "tools" / "v2" / "status_footer.py")],
        capture_output=True, text=True, timeout=5, encoding="utf-8",
    )
    body = (r.stdout or "(status unavailable)").strip()
    return _send_tg(body, reply_to)


def cmd_journal(args: list[str], reply_to: str | None) -> int:
    n = 30
    if args:
        try:
            n = max(1, min(200, int(args[0])))
        except ValueError:
            pass
    sess = _current_session()
    if not sess:
        return _send_tg("journal: no active session id", reply_to)
    jp = REPO_ROOT / "memory" / "sessions" / sess / "journal.md"
    if not jp.exists():
        return _send_tg(f"journal: no entries yet for {sess}", reply_to)
    lines = jp.read_text(encoding="utf-8").splitlines()
    entries = [ln for ln in lines if ln.strip().startswith("- [")]
    tail = entries[-n:]
    body = "\n".join(tail) if tail else "_(empty)_"
    out = f"**Journal** — last {len(tail)} of {len(entries)} entries\n\n```\n{body}\n```"
    return _send_tg(out, reply_to)


def cmd_timeline(args: list[str], reply_to: str | None) -> int:
    sess = _current_session()
    if not sess:
        return _send_tg("timeline: no active session id", reply_to)
    tp = REPO_ROOT / "memory" / "sessions" / sess / "timeline.md"
    if not tp.exists():
        return _send_tg(f"timeline: not yet built for {sess}. Run `/compact` first.", reply_to)
    body = tp.read_text(encoding="utf-8")
    if len(body) > 3500:
        body = body[:3500] + "\n\n…(truncated, see file)"
    return _send_tg(body, reply_to)


def cmd_compact(args: list[str], reply_to: str | None) -> int:
    """On-disk compaction-equivalent: distill journal → timeline + checkpoint.

    Runs DETACHED: this handler lives inside the UserPromptSubmit hook, which
    settings.json time-boxes to 15s — but the LLM distill takes up to 180s.
    Running it synchronously here got the hook killed mid-distill and the caller
    saw "distilling…" then nothing. run_hidden.py spawns the whole chain
    (distill → checkpoint → TG confirmation) windowless and fire-and-forget; the
    confirmation message arrives when it finishes."""
    sess = _current_session()
    if not sess:
        return _send_tg("/compact: no active session id", reply_to)

    chain = (
        f'"{PY_EXE}" "{REPO_ROOT / "tools" / "v2" / "timeline.py"}" build {sess}; '
        f'"{PY_EXE}" "{REPO_ROOT / "tools" / "v2" / "journal.py"}" append {sess} '
        f'decision "TG /compact: timeline distilled, checkpoint marker for next-session resumption"; '
        f'"{PY_EXE}" "{REPO_ROOT / "tools" / "tg" / "tg_send.py"}" '
        f'"/compact done — timeline distilled for {sess[-8:]}. Next session start loads it."'
    )
    try:
        subprocess.run(
            [PY_EXE, str(REPO_ROOT / "tools" / "v2" / "run_hidden.py"), "--",
             "C:/Program Files/Git/bin/bash.exe", "-c", chain],
            timeout=15, capture_output=True,
        )
    except Exception as e:
        return _send_tg(f"/compact: failed to spawn distill: {e}", reply_to)

    return _send_tg(
        f"/compact: distilling session {sess[-8:]} in the background (~1-3 min) — "
        "I'll confirm here when the timeline is fresh.",
        reply_to,
    )


def _env_value(key: str) -> str:
    """Read one key from the project .env (no external deps)."""
    env_file = REPO_ROOT / ".env"
    if env_file.exists():
        try:
            for line in env_file.read_text(encoding="utf-8").splitlines():
                s = line.strip()
                if s.startswith(f"{key}=") :
                    return s.split("=", 1)[1].strip()
        except Exception:
            pass
    return os.environ.get(key, "")


def cmd_tasks(args: list[str], reply_to: str | None) -> int:
    sheet_id = _env_value("TASK_BOARD_SHEET_ID")
    if not sheet_id:
        return _send_tg(
            "/tasks: no task board configured. Set TASK_BOARD_SHEET_ID in .env "
            "(a Google Sheet with a `Tasks` tab) to enable this.", reply_to)
    try:
        r = subprocess.run(
            [PY_EXE, str(REPO_ROOT / "tools" / "google" / "google_workspace.py"),
             "sheets-read", sheet_id, "Tasks!A1:F30"],
            capture_output=True, text=True, timeout=15, encoding="utf-8",
        )
        if r.returncode != 0:
            return _send_tg(f"/tasks: sheet read failed\n```\n{r.stderr[:500]}\n```", reply_to)
        body = (r.stdout or "").strip()
        if len(body) > 3500:
            body = body[:3500] + "\n…(truncated)"
        return _send_tg(f"**Task Board (top 30)**\n```\n{body}\n```", reply_to)
    except Exception as e:
        return _send_tg(f"/tasks failed: {e}", reply_to)


def cmd_update(args: list[str], reply_to: str | None) -> int:
    """Update Claude Code and self-restart the bot IF a new version landed.

    Supports `/update dry-run` and `/update check` for safe operator testing —
    these never kill the session. A bare `/update` runs the full flow:
    update_restart.py sends its own TG notice and terminates this session when
    an update lands, so we ack first and then hand off (don't capture output on
    the real path — the process may die mid-run)."""
    sub = (args[0].lower() if args else "")
    script = str(REPO_ROOT / "tools" / "v2" / "update_restart.py")

    if sub in ("dry-run", "dryrun", "dry"):
        _send_tg("/update: dry-run (no restart)…", reply_to)
        r = subprocess.run([PY_EXE, script, "--dry-run"],
                           capture_output=True, text=True, timeout=240, encoding="utf-8")
        body = (r.stdout or r.stderr or "(no output)").strip()
        if len(body) > 3500:
            body = body[:3500] + "\n…(truncated)"
        return _send_tg(f"**/update dry-run**\n```\n{body}\n```", reply_to)

    if sub in ("check", "check-only", "status"):
        r = subprocess.run([PY_EXE, script, "--check-only"],
                           capture_output=True, text=True, timeout=60, encoding="utf-8")
        body = (r.stdout or r.stderr or "(no output)").strip()
        return _send_tg(f"**/update check**\n```\n{body}\n```", reply_to)

    # Full flow. Ack first; update_restart.py owns the "restarting" / "already
    # current" reply and (if updated) terminates this session.
    _send_tg("/update: checking for a Claude Code update…", reply_to)
    try:
        subprocess.run([PY_EXE, script], timeout=300,
                       capture_output=True, text=True, encoding="utf-8")
    except Exception as e:
        return _send_tg(f"/update failed: {e}", reply_to)
    return 0


def cmd_costs(args: list[str], reply_to: str | None) -> int:
    """Roll up memory/metrics/sessions.csv. `/costs [Nd]` filters to last N days."""
    cmd = [PY_EXE, str(REPO_ROOT / "tools" / "v2" / "cost_report.py"), "--tg"]
    if args:
        n = args[0].rstrip("dD")
        if n.isdigit():
            cmd += ["--days", n]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15, encoding="utf-8")
        body = (r.stdout or "").strip() or "costs: no data"
    except Exception as e:
        body = f"costs: failed ({e})"
    return _send_tg(body, reply_to)


def cmd_help(args: list[str], reply_to: str | None) -> int:
    body = (
        "**TG slash commands**\n"
        "• `/status` — system status\n"
        "• `/journal [n]` — last N journal entries (default 30)\n"
        "• `/timeline` — current distilled timeline\n"
        "• `/compact` — distill journal → timeline + checkpoint\n"
        "• `/tasks` — top 30 task board rows\n"
        "• `/costs [Nd]` — per-session cost rollup (optional last-N-days filter)\n"
        "• `/update` — update Claude Code; self-restart the bot if a new version landed\n"
        "  (`/update dry-run` and `/update check` are safe, no restart)\n"
        "• `/help` — this list\n"
    )
    return _send_tg(body, reply_to)


HANDLERS = {
    "/status": cmd_status,
    "/journal": cmd_journal,
    "/timeline": cmd_timeline,
    "/compact": cmd_compact,
    "/tasks": cmd_tasks,
    "/costs": cmd_costs,
    "/update": cmd_update,
    "/help": cmd_help,
}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: tg_commands.py <full prompt text>|- [reply_to_message_id]", file=sys.stderr)
        print("       (pass '-' to read the prompt from stdin — REQUIRED on Windows/", file=sys.stderr)
        print("        Git Bash, where MSYS mangles leading-slash argv into paths)", file=sys.stderr)
        return 1
    raw = argv[1]
    if raw == "-":
        raw = sys.stdin.read()
    raw = raw.strip()
    reply_to = argv[2] if len(argv) >= 3 and argv[2] else None

    if not raw.startswith("/"):
        return 1

    # Tokenize. Tolerate leading "/cmd args..."
    try:
        toks = shlex.split(raw)
    except ValueError:
        toks = raw.split()
    if not toks:
        return 1
    cmd = toks[0].lower()
    args = toks[1:]

    if cmd not in HANDLERS:
        return 1

    handler = HANDLERS[cmd]
    rc = handler(args, reply_to)
    return 0 if rc == 0 else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
