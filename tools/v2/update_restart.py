#!/usr/bin/env python3
"""/update — update Claude Code, and (only if a new version landed) self-restart
the bot session to apply it.

WHY a self-restart dance: the running claude binary is already loaded into
memory, so `claude update` only takes effect on the NEXT launch. And the bot does
`claude --continue`, which resumes the most-recent conversation. If we relaunch
the bot while the current claude is still alive, BOTH processes attach the same
conversation -> state races + double Telegram replies. So the safe sequence is:

    1. run `claude update`
    2. compare `claude --version` before/after
    3. IF updated:
         - post a TG notice ("restarting to apply vX")
         - spawn scripts/restart-bot.ps1 DETACHED, passing the LIVE claude PID
         - terminate the live claude process
       restart-bot.ps1 then polls until that PID is gone and launches a fresh
       bot window (which --continue-resumes the now-single conversation).
    4. IF already current: report "already on vX", do NOT restart.

Modes:
    (default)      full flow: update + (if needed) notify + spawn restart + kill self
    --dry-run      run version check + `claude update`, print what WOULD happen,
                   but SKIP the TG notice, the restart spawn, and the self-kill
    --check-only   like --dry-run but ALSO skip running `claude update`
                   (pure "what version am I on / is one available" probe)
    --auto         GATED autonomous entrypoint. Runs the full flow ONLY if ALL
                   of: (a) not-checked-today, (b) update-available, (c) session
                   idle. If any gate fails, logs why and exits 0 (no restart).
                   Combine with --dry-run to print the gate decisions WITHOUT
                   restarting. NOT wired to any hook/timer — the Director invokes
                   it deliberately on an autonomous tick once the base is proven.

Exit codes:
    0  handled (updated+restarting, or already current, or dry-run OK)
    2  handled but a step failed (a best-effort notice may have been sent)

# --auto autonomous gate (IMPLEMENTED below; NOT auto-wired to any hook/timer).
# The full flow fires only when ALL THREE gates pass:
#   (a) NOT-CHECKED-TODAY  — daily stamp ~/.claude/.bot_v2_update_stamp (written by
#       launch.ps1 on launch). If it already reads today's date, skip:
#       launch already ran a check today.
#   (b) UPDATE-AVAILABLE   — `claude update` changed the version (ver_before !=
#       ver_after); computed by the existing flow.
#   (c) SESSION-IDLE       — no in-flight work. Idle signal (cheap, available
#       TODAY, no Director cooperation required): the session journal has NOT
#       been modified within BOT_IDLE_MIN minutes (default 5). A live build /
#       subagent run appends to the journal, so a quiet journal == idle. If the
#       Director later writes an explicit memory/sessions/<id>/.busy marker, a
#       FRESH .busy (mtime within the same window) also forces not-idle. .busy
#       absent => fall back to journal-mtime alone (does not block).
# Rationale for journal-mtime over proc-walking children: it needs zero new
# plumbing, can't false-IDLE during an active build (every build writes the
# journal), and degrades safe (unreadable journal => treated as BUSY, so we
# never restart blind). Gate (c) is the conservative one: when unsure, BUSY.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PS_EXE = os.path.join(
    os.environ.get("SystemRoot", r"C:\Windows"),
    "System32", "WindowsPowerShell", "v1.0", "powershell.exe",
)


def _claude_exe() -> str:
    """Resolve the claude binary path. CLAUDE_CODE_EXECPATH is set by the harness
    in our environment; fall back to the known native-install location."""
    env_path = os.environ.get("CLAUDE_CODE_EXECPATH")
    if env_path and Path(env_path).exists():
        return env_path
    fallback = Path(os.environ.get("USERPROFILE", "")) / ".local" / "bin" / "claude.exe"
    return str(fallback)


def _claude_version(exe: str) -> str:
    """First line of `claude --version`, e.g. '2.1.170 (Claude Code)'. '' on failure."""
    try:
        r = subprocess.run([exe, "--version"], capture_output=True, text=True,
                           timeout=30, encoding="utf-8")
        out = (r.stdout or "").strip().splitlines()
        return out[0].strip() if out else ""
    except Exception as e:
        print(f"version probe failed: {e}", file=sys.stderr)
        return ""


def _run_update(exe: str) -> str:
    """Run `claude update`. Returns combined output (for logging). Never raises."""
    try:
        r = subprocess.run([exe, "update"], capture_output=True, text=True,
                           timeout=180, encoding="utf-8")
        return ((r.stdout or "") + (r.stderr or "")).strip()
    except Exception as e:
        return f"claude update failed: {e}"


def _proc_map() -> dict[int, tuple[int, str]]:
    """pid -> (ppid, lowercased name) via Get-CimInstance. {} on failure."""
    ps = ("Get-CimInstance Win32_Process | "
          "Select-Object ProcessId,ParentProcessId,Name | ConvertTo-Json -Compress")
    try:
        r = subprocess.run([PS_EXE, "-NoProfile", "-NonInteractive", "-Command", ps],
                           capture_output=True, text=True, timeout=30, encoding="utf-8")
        data = json.loads(r.stdout)
        if isinstance(data, dict):
            data = [data]
        return {int(d["ProcessId"]): (int(d["ParentProcessId"]),
                (d.get("Name") or "").lower()) for d in data}
    except Exception as e:
        print(f"proc_map failed: {e}", file=sys.stderr)
        return {}


def _live_claude_pid() -> int | None:
    """Resolve the LIVE claude session PID = nearest claude.exe ancestor of this
    process. We are a child of the claude that ran /update, so walking parents
    finds the correct one even when multiple claude.exe processes exist
    (e.g. parallel agent sessions)."""
    m = _proc_map()
    if not m:
        return None
    cur = os.getpid()
    seen: set[int] = set()
    while cur in m and cur not in seen:
        seen.add(cur)
        ppid, name = m[cur]
        if name == "claude.exe":
            return cur
        cur = ppid
    return None


def _old_shell_pid(claude_pid: int) -> int | None:
    """Resolve the launcher SHELL pid = parent of the live claude.exe, but ONLY
    if that parent is powershell.exe / pwsh.exe (the bot launcher shell = the
    window). The verified launch chain is:
        windowsterminal.exe -> powershell.exe (launcher) -> claude.exe -> children
    Killing this shell closes the OLD window after restart. Returns None if the
    parent is anything else (e.g. code.exe) so we never kill an arbitrary parent.
    """
    m = _proc_map()
    if not m or claude_pid not in m:
        return None
    ppid, _ = m[claude_pid]
    parent = m.get(ppid)
    if not parent:
        return None
    _, pname = parent
    if pname in ("powershell.exe", "pwsh.exe"):
        return ppid
    return None


def _send_tg(text: str) -> None:
    try:
        subprocess.run(
            [sys.executable or "python", str(REPO_ROOT / "tools" / "tg_send.py"),
             "--quiet", "--no-status", text],
            capture_output=True, text=True, timeout=15, encoding="utf-8",
        )
    except Exception as e:
        print(f"tg_send failed: {e}", file=sys.stderr)


def _spawn_restart_detached(old_pid: int, dry_run: bool = False,
                            old_shell_pid: int | None = None) -> None:
    """Spawn restart-bot.ps1 fully detached so it survives THIS process's death
    (we are about to terminate the whole claude tree, this script included).

    WHY this exact mechanism: Python's DETACHED_PROCESS creation flag breaks
    `powershell -File` (the script body silently never runs — no console handle),
    and CREATE_NO_WINDOW does run the script but the child is still killed when
    the parent claude tree is terminated. The reliable Windows fire-and-forget
    is to let PowerShell's own `Start-Process -WindowStyle Hidden` launch the
    poller: that creates a fully OS-orphaned, windowless process that both runs
    the -File script AND survives our death. Verified by test (kill parent ->
    child keeps polling and relaunches). The thin launching powershell exits
    immediately; the orphaned poller lives on.

    old_shell_pid (when present) is the launcher shell (powershell/pwsh) that owns
    the OLD window; it is passed to restart-bot.ps1 as -OldShellPid so the
    DETACHED relauncher closes it AFTER the claude PID exits. We do the close in
    the relauncher (not here) to avoid the cascade-race where this dying python
    is itself a descendant of that shell.
    """
    script = REPO_ROOT / "scripts" / "restart-bot.ps1"
    inner_args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                  "-File", str(script), "-OldPid", str(old_pid)]
    if old_shell_pid:
        inner_args += ["-OldShellPid", str(old_shell_pid)]
    if dry_run:
        inner_args.append("-DryRun")
    # Build the Start-Process arg list as a PowerShell single-quoted array.
    ps_arglist = ",".join("'" + a.replace("'", "''") + "'" for a in inner_args)
    launch = (f"Start-Process -FilePath '{PS_EXE}' -WindowStyle Hidden "
              f"-ArgumentList {ps_arglist}")
    subprocess.run(
        [PS_EXE, "-NoProfile", "-NonInteractive", "-Command", launch],
        capture_output=True, text=True, timeout=15,
    )


def _terminate_pid(pid: int) -> None:
    """Terminate the live claude process so restart-bot can safely relaunch."""
    try:
        subprocess.run([PS_EXE, "-NoProfile", "-NonInteractive", "-Command",
                        f"Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue"],
                       capture_output=True, text=True, timeout=15)
    except Exception as e:
        print(f"terminate failed: {e}", file=sys.stderr)


# ---------------------------------------------------------------------------
# --auto gate logic (gates a/c; gate b is the existing version-delta check)
# ---------------------------------------------------------------------------

import datetime  # noqa: E402  (local to the gate code)

STAMP_FILE = Path(os.environ.get("USERPROFILE", "")) / ".claude" / ".bot_v2_update_stamp"
IDLE_MIN = float(os.environ.get("BOT_IDLE_MIN", "5"))


def _current_session_id() -> str | None:
    """Resolve the live session id from the marker the SessionStart hook writes."""
    f = REPO_ROOT / ".claude" / ".current_session_id"
    try:
        sid = f.read_text(encoding="utf-8").strip()
        return sid or None
    except OSError:
        return None


def gate_not_checked_today() -> tuple[bool, str]:
    """(a) Pass if the daily stamp is absent or not today's date."""
    today = datetime.date.today().isoformat()
    try:
        last = STAMP_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return True, f"no stamp file ({STAMP_FILE}); treat as not-checked-today"
    if last == today:
        return False, f"already checked today (stamp={last})"
    return True, f"stamp is {last or '(empty)'}, today is {today}"


def gate_session_idle(now: float | None = None) -> tuple[bool, str]:
    """(c) Idle iff the live session journal has NOT been touched within
    IDLE_MIN minutes AND no fresh .busy marker. Conservative: when the session
    or journal can't be resolved/read, return BUSY (do not restart blind)."""
    now = now if now is not None else __import__("time").time()
    window = IDLE_MIN * 60
    sid = _current_session_id()
    if not sid:
        return False, "no .current_session_id -> cannot confirm idle, treat as BUSY"
    sess_dir = REPO_ROOT / "memory" / "sessions" / sid
    busy = sess_dir / ".busy"
    try:
        if busy.exists() and (now - busy.stat().st_mtime) < window:
            age = round((now - busy.stat().st_mtime) / 60, 1)
            return False, f".busy marker fresh ({age}m old) -> BUSY"
    except OSError:
        pass  # busy unreadable -> fall through to journal mtime
    journal = sess_dir / "journal.md"
    try:
        age_s = now - journal.stat().st_mtime
    except OSError:
        return False, f"journal unreadable ({journal}) -> treat as BUSY"
    age_m = round(age_s / 60, 1)
    if age_s < window:
        return False, f"journal modified {age_m}m ago (< {IDLE_MIN}m) -> BUSY"
    return True, f"journal quiet for {age_m}m (>= {IDLE_MIN}m), no fresh .busy -> IDLE"


def run_auto(dry_run: bool, exe: str) -> int:
    """Gated autonomous flow. Evaluate gates (a) and (c) up front (cheap, no
    side effects), then run the version-check flow as gate (b). Only if ALL
    pass do we proceed to the real update+restart. Always exits 0 unless a
    real update step fails."""
    g_a_pass, g_a_why = gate_not_checked_today()
    g_c_pass, g_c_why = gate_session_idle()

    print("=== --auto gate evaluation ===")
    print(f"  (a) not-checked-today : {'PASS' if g_a_pass else 'FAIL'} — {g_a_why}")
    print(f"  (c) session-idle      : {'PASS' if g_c_pass else 'FAIL'} — {g_c_why}")

    if not (g_a_pass and g_c_pass):
        # Short-circuit before touching `claude update` — gate b not even checked.
        print("  (b) update-available  : SKIPPED (a/c did not both pass)")
        print("--auto: gate(s) failed -> no update/restart. exit 0.")
        return 0

    print("  (a)+(c) passed; now checking (b) update-available via version delta...")
    ver_before = _claude_version(exe)
    update_out = _run_update(exe)
    ver_after = _claude_version(exe)
    updated = bool(ver_before and ver_after and ver_before != ver_after)
    print(f"  (b) update-available  : {'PASS' if updated else 'FAIL'} — {ver_before or '?'} -> {ver_after or '?'}")
    if update_out:
        print(f"--- claude update output ---\n{update_out}")

    if not updated:
        print("--auto: no new version -> no restart. exit 0.")
        return 0

    old_pid = _live_claude_pid()
    shell_pid = _old_shell_pid(old_pid) if old_pid else None
    notice = f"/update(auto): updated {ver_before} -> {ver_after}. Restarting the bot to apply."
    if dry_run:
        print("DRY-RUN(auto): all gates passed + update landed. WOULD:")
        print(f"  - TG notice: {notice}")
        print(f"  - spawn restart-bot.ps1 -OldPid {old_pid} (detached, -Continue relaunch)")
        if shell_pid:
            print(f"  - pass -OldShellPid {shell_pid} (relauncher closes old window)")
        print(f"  - terminate live claude pid {old_pid}")
        if old_pid:
            _spawn_restart_detached(old_pid, dry_run=True, old_shell_pid=shell_pid)
        return 0
    if old_pid is None:
        msg = (f"/update(auto): updated {ver_before} -> {ver_after}, but could NOT resolve "
               f"the live claude PID. NOT auto-restarting — run `mybot` manually.")
        print(msg)
        _send_tg(msg)
        return 2
    _send_tg(notice)
    _spawn_restart_detached(old_pid, dry_run=False, old_shell_pid=shell_pid)
    print(f"spawned restart-bot.ps1 -OldPid {old_pid} (shell={shell_pid}); terminating self ({old_pid})")
    _terminate_pid(old_pid)
    return 0


def run_restart_only(dry_run: bool) -> int:
    """SMOKE TEST entrypoint: exercise ONLY the self-restart dance — no update.
    Proves that the live window can relaunch itself (spawn detached
    restart-bot.ps1, which waits for our PID to exit then `mybot -Continue`s).
    --dry-run logs the would-do and spawns restart-bot in -DryRun (no kill)."""
    old_pid = _live_claude_pid()
    if old_pid is None:
        msg = "/update --restart-only: could NOT resolve the live claude PID — aborting (no restart)."
        print(msg)
        if not dry_run:
            _send_tg(msg)
        return 2

    shell_pid = _old_shell_pid(old_pid)

    if dry_run:
        print(f"DRY-RUN(restart-only): WOULD spawn restart-bot.ps1 -OldPid {old_pid} then terminate {old_pid}.")
        if shell_pid:
            print(f"DRY-RUN(restart-only): resolved launcher shell PID {shell_pid}; WOULD pass -OldShellPid {shell_pid} (relauncher closes old window).")
        else:
            print("DRY-RUN(restart-only): launcher shell PID NOT resolved (parent not powershell/pwsh); old window will be left as-is.")
        _spawn_restart_detached(old_pid, dry_run=True, old_shell_pid=shell_pid)
        print("DRY-RUN(restart-only): spawned restart-bot.ps1 -DryRun (logs 'would relaunch', no kill).")
        return 0

    notice = ("/update --restart-only (SMOKE TEST): restarting the bot now to verify "
              "self-restart. Back in ~30s, --continue-resuming this conversation.")
    print(notice)
    _send_tg(notice)
    _spawn_restart_detached(old_pid, dry_run=False, old_shell_pid=shell_pid)
    print(f"spawned restart-bot.ps1 -OldPid {old_pid} (shell={shell_pid}); terminating self ({old_pid})")
    _terminate_pid(old_pid)
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="update_restart")
    ap.add_argument("--dry-run", action="store_true",
                    help="run update + version check; SKIP notice/restart/kill")
    ap.add_argument("--check-only", action="store_true",
                    help="version probe only; do NOT run `claude update` either")
    ap.add_argument("--auto", action="store_true",
                    help="gated autonomous flow (gates a/b/c); combine with --dry-run")
    ap.add_argument("--restart-only", action="store_true",
                    help="SMOKE TEST: skip the update entirely; just exercise the "
                         "self-restart dance (spawn detached restart-bot.ps1 + kill "
                         "this claude). Combine with --dry-run to log without killing.")
    args = ap.parse_args(argv[1:])

    if args.restart_only:
        return run_restart_only(dry_run=args.dry_run)

    exe = _claude_exe()
    if not Path(exe).exists():
        msg = f"/update: claude binary not found at {exe}"
        print(msg)
        if not (args.dry_run or args.check_only or args.auto):
            _send_tg(msg)
        return 2

    if args.auto:
        return run_auto(dry_run=args.dry_run, exe=exe)

    ver_before = _claude_version(exe)

    if args.check_only:
        print(f"check-only: current version = {ver_before or '(unreadable)'}")
        print("check-only: skipping `claude update` and restart")
        return 0

    update_out = _run_update(exe)
    ver_after = _claude_version(exe)
    updated = bool(ver_before and ver_after and ver_before != ver_after)

    print(f"version before: {ver_before or '(unreadable)'}")
    print(f"version after:  {ver_after or '(unreadable)'}")
    print(f"updated: {updated}")
    if update_out:
        print(f"--- claude update output ---\n{update_out}")

    if not updated:
        status = f"/update: already current ({ver_after or ver_before or 'unknown'})"
        print(status)
        if not args.dry_run:
            _send_tg(status)
        return 0

    # --- updated: prepare self-restart -------------------------------------
    old_pid = _live_claude_pid()
    shell_pid = _old_shell_pid(old_pid) if old_pid else None
    notice = f"/update: updated {ver_before} -> {ver_after}. Restarting the bot to apply (will --continue this conversation)."

    if args.dry_run:
        print("DRY-RUN: an update landed. WOULD do:")
        print(f"  - TG notice: {notice}")
        print(f"  - spawn restart-bot.ps1 -OldPid {old_pid} (detached)")
        if shell_pid:
            print(f"  - pass -OldShellPid {shell_pid} (relauncher closes old window)")
        print(f"  - terminate live claude pid {old_pid}")
        if old_pid:
            print("DRY-RUN: spawning restart-bot.ps1 in -DryRun (it will log a 'would relaunch', no kill)")
            _spawn_restart_detached(old_pid, dry_run=True, old_shell_pid=shell_pid)
        else:
            print("DRY-RUN: could NOT resolve live claude pid (would abort restart in real run)")
        return 0

    if old_pid is None:
        # Can't safely restart without knowing which claude to kill/wait-on.
        msg = (f"/update: updated {ver_before} -> {ver_after}, but could NOT resolve "
               f"the live claude PID. NOT auto-restarting — run `mybot` manually to apply.")
        print(msg)
        _send_tg(msg)
        return 2

    _send_tg(notice)
    _spawn_restart_detached(old_pid, dry_run=False, old_shell_pid=shell_pid)
    # Give the detached child a moment to start its PID-poll before we die.
    print(f"spawned restart-bot.ps1 -OldPid {old_pid} (shell={shell_pid}); terminating self ({old_pid})")
    _terminate_pid(old_pid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
