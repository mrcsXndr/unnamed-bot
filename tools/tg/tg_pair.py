#!/usr/bin/env python3
"""tg_pair — pre-authorize a Telegram chat id with the official channel plugin.

Merges <chat_id> into the `allowFrom` list of
~/.claude/channels/telegram/access.json, so the owner's FIRST message is
accepted without the /telegram:access pairing dance. For a direct message the
chat id equals the sender's user id, which is exactly what allowFrom holds.

Idempotent: existing entries, groups and policy are preserved; re-running
with the same id is a no-op. The setup wizard calls this automatically when
you provide a chat id; you can also run it by hand.

Usage: python tools/tg/tg_pair.py <chat_id>
Exit:  0 ok, 1 write failure, 2 bad usage
"""
from __future__ import annotations

import json
import os
import sys

ACCESS_PATH = os.path.join(
    os.path.expanduser("~"), ".claude", "channels", "telegram", "access.json"
)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not argv[1].strip():
        print(__doc__.strip(), file=sys.stderr)
        return 2
    chat_id = argv[1].strip()

    data: dict = {"dmPolicy": "pairing", "allowFrom": [], "groups": {}, "pending": {}}
    try:
        with open(ACCESS_PATH, encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            data.update(loaded)
    except (OSError, ValueError):
        pass  # missing/corrupt file -> start from the defaults above

    allow = data.get("allowFrom")
    if not isinstance(allow, list):
        allow = data["allowFrom"] = []
    if chat_id not in {str(a) for a in allow}:
        allow.append(chat_id)

    try:
        os.makedirs(os.path.dirname(ACCESS_PATH), exist_ok=True)
        with open(ACCESS_PATH, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
    except OSError as e:
        print(f"tg_pair: could not write {ACCESS_PATH}: {e}", file=sys.stderr)
        return 1

    print(f"tg_pair: chat id {chat_id} authorized in {ACCESS_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
