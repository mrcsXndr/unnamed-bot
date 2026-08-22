#!/usr/bin/env python3
"""Tests for the memory-graph half of recall.py.

Run: PYTHONIOENCODING=utf-8 python tools/v2/test_recall_graph.py

Everything runs against a TEMP memory dir + TEMP db — the real
memory/index/recall.db is never touched. Ordering matters: the positive
controls come first, so a later "no links found" / "no rows found" assertion
can't quietly be passing because the parser or the indexer never ran at all
(a check that cannot fail).
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import recall  # noqa: E402

FAILS: list[str] = []
CHECKS = 0


def check(cond: bool, label: str) -> None:
    global CHECKS
    CHECKS += 1
    if cond:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}")
        FAILS.append(label)


def mem(name: str, description: str, body: str, extra_fm: str = "") -> str:
    return (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        "metadata:\n"
        "  node_type: memory\n"
        "  type: feedback\n"
        f"{extra_fm}"
        "---\n\n"
        f"{body}\n"
    )


# ---------------------------------------------------------------------------
# _parse_memory
# ---------------------------------------------------------------------------
print("\n== _parse_memory ==")

# POSITIVE CONTROL FIRST: prove the link regex actually fires before any test
# asserts that it found nothing.
node = recall._parse_memory(
    mem("alpha", "the alpha fact", "Body links [[beta]] and [[gamma-two]].\nAlso [[beta]] again."),
    "fallback",
)
check(node["links"] == ["beta", "gamma-two"], "positive control: finds + dedupes + sorts links")
check(node["name"] == "alpha", "name from front-matter")
check(node["description"] == "the alpha fact", "description from front-matter")
check(node["entry"]["kind"] == "memory", "entry kind is 'memory'")
check(node["entry"]["seq"] == 0, "one file = one entry at seq 0")
check("the alpha fact" in node["entry"]["text"], "entry text carries the description")
check("[alpha]" in node["entry"]["text"], "entry text carries the name (so a slug query hits)")
check("\n" not in node["entry"]["text"], "entry text is flattened to one line")

no_links = recall._parse_memory(mem("solo", "no edges here", "Plain body, no links."), "fb")
check(no_links["links"] == [], "a body with no wiki-links yields no edges")

self_link = recall._parse_memory(mem("selfy", "d", "Points at [[selfy]] and [[other]]."), "fb")
check(self_link["links"] == ["other"], "a self-link is not an edge")

fm_only = recall._parse_memory(
    "---\nname: fmnode\ndescription: has [[ghost]] in the description\n---\n\nBody with [[real]].\n",
    "fb",
)
check(fm_only["links"] == ["real"], "edges come from the body, not the front-matter")

bare = recall._parse_memory("Just a body, no front-matter at all. [[x]]\n", "fallback-slug")
check(bare["name"] == "fallback-slug", "missing front-matter falls back to the filename stem")
check(bare["links"] == ["x"], "links still parsed without front-matter")

with_ts = recall._parse_memory(
    mem("tsn", "d", "b", extra_fm="  modified: 2026-08-21T17:50:00.033Z\n  originSessionId: sess-99\n"),
    "fb",
)
check(with_ts["entry"]["ts"] == "2026-08-21T17:50:00.033Z", "modified -> ts")
check(with_ts["entry"]["session_id"] == "sess-99", "originSessionId -> session_id")

no_origin = recall._parse_memory(mem("noorig", "d", "b"), "fb")
check(no_origin["entry"]["session_id"] == "memory", "no originSessionId -> session_id 'memory'")


# ---------------------------------------------------------------------------
# End-to-end index against a temp memory dir
# ---------------------------------------------------------------------------
print("\n== index + graph ==")

tmp = tempfile.TemporaryDirectory()
tmp_path = Path(tmp.name)
mem_dir = tmp_path / "memory"
mem_dir.mkdir()
idx_dir = tmp_path / "index"

(mem_dir / "hub.md").write_text(
    mem("hub", "the hub fact", "Links [[leaf-a]], [[leaf-b]] and [[never-written]]."),
    encoding="utf-8",
)
(mem_dir / "leaf-a.md").write_text(mem("leaf-a", "leaf a fact", "Back to [[hub]]."), encoding="utf-8")
(mem_dir / "leaf-b.md").write_text(mem("leaf-b", "leaf b fact", "No links."), encoding="utf-8")
(mem_dir / "MEMORY.md").write_text("# Memory Index\n- [Hub](hub.md) — pointer only\n", encoding="utf-8")

# Point the module at the sandbox. Sessions/timelines are pointed at an empty
# dir so this test indexes ONLY the fixture memories.
orig = (recall.MEMORY_DIR, recall.INDEX_DIR, recall.DB_PATH, recall.SESSIONS_DIR, recall.TIMELINES_DIR)
recall.MEMORY_DIR = mem_dir
recall.INDEX_DIR = idx_dir
recall.DB_PATH = idx_dir / "recall.db"
recall.SESSIONS_DIR = tmp_path / "no-sessions"
recall.TIMELINES_DIR = tmp_path / "no-timelines"

try:
    rc = recall.cmd_index()
    check(rc == 0, "index returns 0")

    con = recall._connect()
    names = {r[0] for r in con.execute("SELECT name FROM memory_files")}
    check(names == {"hub", "leaf-a", "leaf-b"}, f"3 nodes indexed, MEMORY.md skipped (got {sorted(names)})")

    edges = {(r[0], r[1]) for r in con.execute("SELECT src, dst FROM memory_links")}
    check(
        edges == {("hub", "leaf-a"), ("hub", "leaf-b"), ("hub", "never-written"), ("leaf-a", "hub")},
        f"4 edges incl. the dangling one (got {sorted(edges)})",
    )

    hub_path = str(mem_dir / "hub.md")
    nbs = recall._neighbours(con, hub_path)
    by_name = {n["name"]: n for n in nbs}
    check(set(by_name) == {"leaf-a", "leaf-b", "never-written"}, "hub has 3 neighbours")
    check(by_name["leaf-a"]["direction"] == "out", "out-edge reported as 'out'")
    check(by_name["leaf-a"]["description"] == "leaf a fact", "neighbour carries its description")
    check(by_name["never-written"]["exists"] is False, "dangling neighbour reported with exists=False")
    check(by_name["never-written"]["description"] is None, "dangling neighbour has no description")

    leaf_b_nbs = recall._neighbours(con, str(mem_dir / "leaf-b.md"))
    check([n["name"] for n in leaf_b_nbs] == ["hub"], "leaf-b sees hub via its IN-edge only")
    check(leaf_b_nbs[0]["direction"] == "in", "in-edge reported as 'in'")

    check(len(recall._neighbours(con, hub_path, cap=2)) == 2, "cap truncates the expansion")
    check(recall._neighbours(con, str(mem_dir / "nope.md")) == [], "unknown path -> no neighbours")

    # A memory hit must be findable by its BODY text, not just its slug.
    con.row_factory = __import__("sqlite3").Row
    rows = recall._run_search_query(con, "dangling OR leaf", 10, 0.0)
    check(len(rows) > 0, "positive control: FTS finds the fixture memories")

    # --- rename inside a file replaces the node, no ghost ---
    (mem_dir / "leaf-b.md").write_text(
        mem("leaf-b-renamed", "leaf b fact", "No links."), encoding="utf-8"
    )
    recall.cmd_index()
    con2 = recall._connect()
    names2 = {r[0] for r in con2.execute("SELECT name FROM memory_files")}
    check("leaf-b" not in names2, "renaming the `name:` field leaves no ghost node")
    check("leaf-b-renamed" in names2, "the renamed node is present")

    # --- deleting a memory must remove it from FTS, not just from the table ---
    hub_ids_before = [r[0] for r in con2.execute("SELECT id FROM entries WHERE source_path=?", (hub_path,))]
    check(len(hub_ids_before) == 1, "positive control: hub has an entries row before deletion")
    (mem_dir / "hub.md").unlink()
    out_rc = recall.cmd_index()
    check(out_rc == 0, "index after a deletion still returns 0")
    con3 = recall._connect()
    con3.row_factory = __import__("sqlite3").Row
    left = con3.execute("SELECT COUNT(*) FROM entries WHERE source_path=?", (hub_path,)).fetchone()[0]
    check(left == 0, "deleted memory's entries row is pruned")
    check(
        con3.execute("SELECT COUNT(*) FROM memory_files WHERE name='hub'").fetchone()[0] == 0,
        "deleted memory's node is pruned",
    )
    check(
        con3.execute("SELECT COUNT(*) FROM memory_links WHERE src='hub'").fetchone()[0] == 0,
        "deleted memory's out-edges are pruned",
    )
    fts_hits = recall._run_search_query(con3, '"the hub fact"', 10, 0.0)
    check(len(fts_hits) == 0, "deleted memory returns no search results")
    # The JOIN in _run_search_query hides an orphaned FTS row (it joins to
    # nothing), so the assertion above passes even when the FTS delete is
    # skipped — it cannot see this bug. Query the FTS table DIRECTLY, and make
    # SQLite audit its own external-content invariant. Mutation-checked: with
    # the 'delete' command removed, the direct MATCH below goes red — the
    # integrity-check does NOT (it tolerates an orphan row), so it is a guard
    # against a different corruption, not extra coverage of this one.
    check(
        con3.execute("SELECT COUNT(*) FROM entries_fts WHERE entries_fts MATCH ?",
                     ('"the hub fact"',)).fetchone()[0] == 0,
        "deleted memory's FTS row is gone from the FTS table itself",
    )
    try:
        con3.execute("INSERT INTO entries_fts(entries_fts) VALUES('integrity-check')")
        integrity_ok = True
    except Exception:
        integrity_ok = False
    check(integrity_ok, "FTS index still agrees with the entries table after a prune")
    # ...and the survivors are still searchable, so the prune wasn't a wipe.
    check(len(recall._run_search_query(con3, "leaf", 10, 0.0)) > 0, "prune did not wipe the surviving rows")

finally:
    (recall.MEMORY_DIR, recall.INDEX_DIR, recall.DB_PATH,
     recall.SESSIONS_DIR, recall.TIMELINES_DIR) = orig
    try:
        tmp.cleanup()
    except Exception:
        pass  # Windows holds the WAL file open; the temp dir is disposable


# ---------------------------------------------------------------------------
# memory dir resolution
# ---------------------------------------------------------------------------
print("\n== memory dir resolution ==")
os.environ["BOT_MEMORY_DIR"] = str(tmp_path / "override")
check(recall._default_memory_dir() == tmp_path / "override", "BOT_MEMORY_DIR overrides the derived path")
del os.environ["BOT_MEMORY_DIR"]
derived = recall._default_memory_dir()
check(derived.parent.name.startswith("C--Users"), f"derived CC project slug looks right ({derived.parent.name})")
check(derived.name == "memory", "derived path ends in /memory")


print(f"\n{CHECKS - len(FAILS)}/{CHECKS} checks passed")
if FAILS:
    for f in FAILS:
        print(f"  FAILED: {f}")
    sys.exit(1)
