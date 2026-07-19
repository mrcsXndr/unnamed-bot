#!/usr/bin/env python3
"""Per-session cost meter (Phase 0).

Computes the real USD cost of ONE Claude Code session from its transcript
JSONL and appends a single row to memory/metrics/sessions.csv.

Why
---
There was zero per-session token/cost instrumentation. `statusline.js`
only produces a lifetime EUR total pooled across ALL projects, so it
cannot answer "what did THIS session cost" or compare projects. This
script does, by parsing the same source data the statusline does:

  ~/.claude/projects/<project-slug>/<session>.jsonl

Each assistant turn carries `message.usage` (input / output / cache_read /
cache_creation tokens + model). One JSONL file == one session id
(filename == sessionId). Pricing mirrors tools/infra/statusline.js PRICING.

Output (memory/metrics/sessions.csv), header written if absent:
  session_id,ts_start,ts_end,project,input_tok,output_tok,
  cache_read_tok,cache_creation_tok,subagent_count,model_mix,usd_est

Usage
-----
  cost_meter.py <session_id> [project_slug]
  cost_meter.py --stdin              # read Stop-hook JSON payload from stdin
  cost_meter.py --jsonl <path>       # price an explicit transcript file

Design: fail-open. Any error prints a diagnostic to stderr and exits 0,
because this runs on the Stop hook of a LIVE session and must NEVER block
session end.
"""
from __future__ import annotations

import csv
import json
import os
import sys
from pathlib import Path

# Pricing per MILLION tokens (USD). Mirrors tools/infra/statusline.js PRICING.
PRICING = {
    "opus": {"input": 15.0, "cache_write": 3.75, "cache_read": 1.50, "output": 75.0},
    "sonnet": {"input": 3.0, "cache_write": 0.75, "cache_read": 0.30, "output": 15.0},
    "haiku": {"input": 0.8, "cache_write": 0.20, "cache_read": 0.08, "output": 4.0},
}

REPO_ROOT = Path(__file__).resolve().parents[2]
METRICS_DIR = REPO_ROOT / "memory" / "metrics"
CSV_PATH = METRICS_DIR / "sessions.csv"

# Default project slug for this repo. Claude Code derives it from the cwd by
# replacing path separators + the drive colon with hyphens
# (e.g. C:\Users\me\Code\my-bot -> C--Users-me-Code-my-bot), so compute it
# from wherever this repo actually lives.
DEFAULT_PROJECT_SLUG = str(REPO_ROOT).replace(":", "-").replace("\\", "-").replace("/", "-")

CSV_HEADER = [
    "session_id",
    "ts_start",
    "ts_end",
    "project",
    "input_tok",
    "output_tok",
    "cache_read_tok",
    "cache_creation_tok",
    "subagent_count",
    "model_mix",
    "usd_est",
]


def _tier(model: str | None) -> str:
    m = (model or "").lower()
    if "sonnet" in m:
        return "sonnet"
    if "haiku" in m:
        return "haiku"
    return "opus"


def _projects_dir() -> Path:
    # Honor CLAUDE_CONFIG_DIR so per-personality bot instances (which set their
    # own config home) price the right transcript, not the real ~/.claude.
    # Falls back to ~/.claude when unset.
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(cfg) if cfg else Path(os.path.expanduser("~")) / ".claude"
    return base / "projects"


def _find_jsonl(session_id: str, project_slug: str) -> Path | None:
    """Locate the transcript for a session. Filename == sessionId, but if a
    direct hit fails, fall back to scanning the project dir for a file whose
    first/any line carries that sessionId (handles renamed/continued files)."""
    proj = _projects_dir() / project_slug
    direct = proj / f"{session_id}.jsonl"
    if direct.exists():
        return direct
    if not proj.exists():
        return None
    # Fallback: scan files in this project dir for the session id.
    for f in proj.glob("*.jsonl"):
        try:
            with f.open(encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if not line.strip():
                        continue
                    try:
                        if json.loads(line).get("sessionId") == session_id:
                            return f
                    except Exception:
                        continue
                    break  # only check first non-empty line per file
        except Exception:
            continue
    return None


def _price_jsonl(path: Path) -> dict:
    """Sum priced cost + token totals + subagent count for one transcript."""
    totals = {
        "input": 0,
        "output": 0,
        "cache_read": 0,
        "cache_creation": 0,
        "usd": 0.0,
        "subagents": 0,
        "ts_start": None,
        "ts_end": None,
        "models": {},  # tier -> count of assistant turns
    }
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue

            ts = entry.get("timestamp")
            if ts:
                if totals["ts_start"] is None or ts < totals["ts_start"]:
                    totals["ts_start"] = ts
                if totals["ts_end"] is None or ts > totals["ts_end"]:
                    totals["ts_end"] = ts

            if entry.get("type") != "assistant":
                continue
            msg = entry.get("message") or {}
            usage = msg.get("usage") or {}
            tier = _tier(msg.get("model"))
            price = PRICING[tier]

            inp = int(usage.get("input_tokens") or 0)
            out = int(usage.get("output_tokens") or 0)
            cr = int(usage.get("cache_read_input_tokens") or 0)
            cc = int(usage.get("cache_creation_input_tokens") or 0)

            totals["input"] += inp
            totals["output"] += out
            totals["cache_read"] += cr
            totals["cache_creation"] += cc
            totals["usd"] += (
                inp * price["input"]
                + cc * price["cache_write"]
                + cr * price["cache_read"]
                + out * price["output"]
            ) / 1e6
            totals["models"][tier] = totals["models"].get(tier, 0) + 1

            content = msg.get("content")
            if isinstance(content, list):
                for blk in content:
                    if (
                        isinstance(blk, dict)
                        and blk.get("type") == "tool_use"
                        and blk.get("name") in ("Agent", "Task")
                    ):
                        totals["subagents"] += 1
    return totals


def _model_mix(models: dict) -> str:
    # e.g. "opus:142,sonnet:7" — deterministic order, ; would clash with CSV-less
    if not models:
        return ""
    return ",".join(f"{k}:{v}" for k, v in sorted(models.items()))


def _upsert_row(row: list) -> None:
    """Upsert by session_id (row[0]). Exactly one current-total row per
    session. the bot runs one long `--continue` session, so the Stop hook
    re-meters the same growing JSONL repeatedly — without upsert that would
    append a new cumulative row every Stop. We rewrite the CSV with the row
    replaced (or appended if new), via temp-file + os.replace so a crash
    mid-write can't truncate the existing CSV.

    Fail-open: any error here leaves the existing CSV untouched (caller
    already has the printed JSON result; the row just won't persist)."""
    METRICS_DIR.mkdir(parents=True, exist_ok=True)
    session_id = str(row[0])

    rows: list[list[str]] = []
    if CSV_PATH.exists() and CSV_PATH.stat().st_size > 0:
        with CSV_PATH.open("r", newline="", encoding="utf-8") as fh:
            reader = csv.reader(fh)
            for r in reader:
                rows.append(r)

    # Separate header (if present) from data rows.
    header: list[str] | None = None
    data: list[list[str]] = []
    for i, r in enumerate(rows):
        if i == 0 and r[:1] == CSV_HEADER[:1]:
            header = r
        else:
            data.append(r)
    if header is None:
        header = CSV_HEADER

    replaced = False
    str_row = [str(c) for c in row]
    for i, r in enumerate(data):
        if r and r[0] == session_id:
            data[i] = str_row
            replaced = True
            break
    if not replaced:
        data.append(str_row)

    tmp = CSV_PATH.with_suffix(".csv.tmp")
    with tmp.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(header)
        for r in data:
            w.writerow(r)
    os.replace(tmp, CSV_PATH)


def meter(session_id: str, project_slug: str, jsonl_override: Path | None = None) -> int:
    if jsonl_override is not None:
        path = jsonl_override
        if not session_id:
            session_id = path.stem
    else:
        path = _find_jsonl(session_id, project_slug)
    if path is None or not path.exists():
        print(
            f"[cost_meter] no transcript for session {session_id!r} in "
            f"project {project_slug!r}; skipping (fail-open)",
            file=sys.stderr,
        )
        return 0

    t = _price_jsonl(path)
    row = [
        session_id,
        t["ts_start"] or "",
        t["ts_end"] or "",
        project_slug,
        t["input"],
        t["output"],
        t["cache_read"],
        t["cache_creation"],
        t["subagents"],
        _model_mix(t["models"]),
        f"{t['usd']:.4f}",
    ]
    _upsert_row(row)
    print(
        json.dumps(
            {
                "status": "metered",
                "session_id": session_id,
                "usd_est": round(t["usd"], 4),
                "subagent_count": t["subagents"],
                "input_tok": t["input"],
                "output_tok": t["output"],
                "cache_read_tok": t["cache_read"],
                "cache_creation_tok": t["cache_creation"],
                "model_mix": _model_mix(t["models"]),
                "csv": str(CSV_PATH),
            }
        )
    )
    return 0


def _from_stdin() -> tuple[str, str]:
    """Stop hook passes JSON on stdin. Extract session id + transcript path.

    Claude Code Stop-hook payload includes `session_id` and `transcript_path`
    (and sometimes `cwd`). We prefer transcript_path when present (most
    robust), else fall back to session_id + slug lookup."""
    raw = ""
    try:
        if not sys.stdin.isatty():
            raw = sys.stdin.read()
    except Exception:
        raw = ""
    sid, slug = "", DEFAULT_PROJECT_SLUG
    if raw.strip():
        try:
            d = json.loads(raw)
            sid = d.get("session_id") or d.get("sessionId") or ""
            tp = d.get("transcript_path") or d.get("transcriptPath") or ""
            if tp:
                # Stash the explicit transcript path so meter() can use it.
                os.environ["_COST_METER_TRANSCRIPT"] = tp
        except Exception as e:
            print(f"[cost_meter] stdin parse failed: {e!r}", file=sys.stderr)
    return sid, slug


def main(argv: list[str]) -> int:
    try:
        if len(argv) >= 2 and argv[1] == "--jsonl" and len(argv) >= 3:
            return meter("", DEFAULT_PROJECT_SLUG, jsonl_override=Path(argv[2]))

        if len(argv) >= 2 and argv[1] == "--stdin":
            sid, slug = _from_stdin()
            tp = os.environ.get("_COST_METER_TRANSCRIPT", "")
            if tp and Path(tp).exists():
                return meter(sid, slug, jsonl_override=Path(tp))
            if not sid:
                print("[cost_meter] no session_id from stdin; skipping (fail-open)", file=sys.stderr)
                return 0
            return meter(sid, slug)

        if len(argv) < 2:
            print(
                "usage: cost_meter.py <session_id> [project_slug] | --stdin | --jsonl <path>",
                file=sys.stderr,
            )
            return 0  # fail-open even on usage error

        session_id = argv[1]
        slug = argv[2] if len(argv) >= 3 else DEFAULT_PROJECT_SLUG
        return meter(session_id, slug)
    except Exception as e:  # absolute fail-open guard
        print(f"[cost_meter] unexpected error (fail-open): {e!r}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
