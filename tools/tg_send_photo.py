#!/usr/bin/env python3
"""
tg_send_photo.py — send a photo to Telegram via the Bot API.

Stdlib only. Reads TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID from goose-bot/.env.

Usage:
    python tools/tg_send_photo.py <photo_path> [caption]
    python tools/tg_send_photo.py /path/to/screenshot.png "Look at this"
"""

import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / ".env"


def load_env() -> dict:
    env = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if not s or s.startswith("#") or "=" not in s:
                continue
            k, v = s.split("=", 1)
            env[k.strip()] = v.strip()
    return env


CAPTION_LIMIT = 1000  # Telegram's hard limit is 1024; leave headroom for the truncation marker.


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: tg_send_photo.py <photo_path> [caption]")

    photo_path = Path(sys.argv[1])
    if not photo_path.exists():
        sys.exit(f"error: {photo_path} not found")
    caption = sys.argv[2] if len(sys.argv) >= 3 else ""

    # Telegram caps photo captions at 1024 chars. Truncate at a word boundary
    # so we never hit the API limit blind. Caller can pre-trim if they need
    # the full text — this is a safety net.
    if len(caption) > CAPTION_LIMIT:
        cut = caption.rfind(" ", 0, CAPTION_LIMIT - 12)
        if cut < CAPTION_LIMIT // 2:
            cut = CAPTION_LIMIT - 12
        caption = caption[:cut].rstrip() + " [truncated]"

    env = load_env()
    token = env.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = env.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        sys.exit("error: TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID required in .env")

    boundary = f"----GoosePhoto{int(time.time()*1000)}"
    photo_bytes = photo_path.read_bytes()

    body = b""
    body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{chat_id}\r\n".encode("utf-8")
    if caption:
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n{caption}\r\n".encode("utf-8")
    body += (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"photo\"; "
        f"filename=\"{photo_path.name}\"\r\nContent-Type: image/png\r\n\r\n"
    ).encode("utf-8")
    body += photo_bytes
    body += f"\r\n--{boundary}--\r\n".encode("utf-8")

    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendPhoto",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    try:
        resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
        if resp.get("ok"):
            mid = resp.get("result", {}).get("message_id")
            print(f"sent (id: {mid})")
        else:
            sys.exit(f"send failed: {resp}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        sys.exit(f"send error: HTTP {e.code} — {body[:400]}")
    except Exception as e:
        sys.exit(f"send error: {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
