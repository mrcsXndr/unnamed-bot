#!/usr/bin/env python3
"""`add` must take a card body from a FILE, in one call.

Not pytest. Run directly:
  python tools/v2/test_add_body_file.py

Why this exists: a card body is full of backticks and `$`, so the safe way to
pass one is a file — which `edit` supports and `add` must too. The obvious
workaround is add-then-edit, and that loses a race: GitHub's Projects list
reads are eventually consistent, so an `edit` fired immediately after an `add`
often cannot see the new item and dies with "no unique item", leaving a card on
the board with a placeholder body.

Mutation-proved: with the `--body-file` branch removed from `add`, all four
cases go red — the body becomes the literal string "--body-file".

Stubs add_draft/load_cfg; never touches the network or a live board.
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_projects as g  # noqa: E402

BODY = (
    "Body with `backticks`, $DOLLARS, $(command substitution) and \"quotes\".\n"
    "Second line - a file:line reference at foo.ts:42.\n"
)

FAILED = []


def check(name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  -- {detail}" if detail and not cond else ""))
    if not cond:
        FAILED.append(name)


def main() -> int:
    tmp = Path(tempfile.mkdtemp()) / "card.md"
    tmp.write_text(BODY, encoding="utf-8")

    captured: dict[str, str] = {}
    g.load_cfg = lambda *a, **k: {"project_id": "P_fake"}

    def _fake_add(cfg, title, body=""):
        captured["title"], captured["body"] = title, body
        return "PVTI_fake"

    g.add_draft = _fake_add

    print("add --body-file")

    # 1. --body-file reads the file, and shell-hostile content survives verbatim.
    rc = g.main(["gh", "add", "My Title", "--body-file", str(tmp)])
    check("body-file exits 0", rc == 0, f"rc={rc}")
    check("body-file passes the file content verbatim",
          captured.get("body") == BODY, repr(captured.get("body")))

    # 2. The positional form still works (no regression).
    captured.clear()
    rc = g.main(["gh", "add", "T2", "plain body"])
    check("positional body still works", rc == 0 and captured.get("body") == "plain body",
          f"rc={rc} body={captured.get('body')!r}")

    # 3. No body at all -> empty string, still a valid card.
    captured.clear()
    rc = g.main(["gh", "add", "T3"])
    check("no body is an empty body", rc == 0 and captured.get("body") == "",
          f"rc={rc} body={captured.get('body')!r}")

    # 4. --body-file with no path is an ERROR, and must not create a half-card.
    captured.clear()
    rc = g.main(["gh", "add", "T4", "--body-file"])
    check("missing --body-file value exits 2", rc == 2, f"rc={rc}")
    check("no card created on bad args", not captured, str(captured))

    print()
    if FAILED:
        print(f"{len(FAILED)} FAILED: {', '.join(FAILED)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
