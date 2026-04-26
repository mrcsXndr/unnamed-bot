#!/usr/bin/env python3
"""
tg_send.py — send a Telegram message with auto MarkdownV2 conversion + split.

The bot writes natural CommonMark; this script handles Telegram's escape pain.
Designed to replace direct calls to the channel plugin's `reply` tool when
formatting matters.

Usage:
    python tools/tg_send.py "**Hi** with `code`"
    echo "long text" | python tools/tg_send.py
    python tools/tg_send.py --chat-id 7989209848 --reply-to 540 "text"
    python tools/tg_send.py --plain "raw text, no formatting"

Behavior:
    - Reads TELEGRAM_BOT_TOKEN from the project .env
    - Default chat_id = TELEGRAM_CHAT_ID from .env (default user)
    - Converts CommonMark idioms (**bold**, *italic*, `code`, ```block```,
      [text](url)) to Telegram MarkdownV2, escaping every reserved char in
      surrounding text per the spec
    - Splits at 4000 chars on newline boundaries (4096 is Telegram's hard cap)
    - On HTTP 400 parse error, retries the same text in plain mode (no
      formatting, no escaping)
    - Prints sent message_id(s) one per line, exits non-zero on send failure

Exit codes:
    0  all chunks sent
    1  bad arguments / config
    2  Telegram API failure (after fallback)
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / ".env"

# MarkdownV2 reserved chars in normal text. Backslash MUST be escaped first
# (and re.sub handles the ordering correctly because the regex matches the
# literal `\` and replaces it with `\\` before moving past — the inserted `\`
# is not re-scanned). Without `\` in the set, any literal backslash in the
# source becomes Telegram's escape prefix for the next char, which throws a
# parse error if that char isn't a reserved one.
MD2_RESERVED = r"\_*[]()~`>#+-=|{}.!"
MD2_RESERVED_RE = re.compile(r"([\\_\*\[\]\(\)~`>#\+\-=\|\{\}\.!])")

MAX_CHUNK = 4000  # safe under TG's 4096 hard cap
TG_API = "https://api.telegram.org/bot{token}/sendMessage"


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


def escape_md2(text: str) -> str:
    """Escape reserved chars in normal MarkdownV2 text."""
    return MD2_RESERVED_RE.sub(r"\\\1", text)


def escape_md2_url(text: str) -> str:
    """Inside link parens — only ) and \\ need escaping."""
    return text.replace("\\", "\\\\").replace(")", "\\)")


def to_markdownv2(text: str) -> str:
    """
    Convert natural CommonMark text to Telegram MarkdownV2.

    Recognizes:
        ```fenced code blocks```          (preserved verbatim, content not escaped except \\ and `)
        `inline code`                      (preserved verbatim)
        [link text](https://url)           (text escaped, url ) and \\ escaped)
        **bold**                           → *bold*
        *italic*                           (already MD2 syntax — left alone if not part of **)

    Everything else has reserved chars escaped per the MD2 spec.
    Em-dashes and other Unicode pass through clean (not in escape list).
    """
    placeholders: list[str] = []

    def stash(s: str) -> str:
        idx = len(placeholders)
        placeholders.append(s)
        # Use a marker that won't survive escaping naturally — lots of unique chars
        return f"\x00P{idx}P\x00"

    # Step 1 — fenced code blocks (greedy non-overlapping)
    # Inside code blocks, `\` MUST be escaped to `\\` per MD2 spec — otherwise
    # a stray `\` consumes the next char (potentially the closing backtick) and
    # the entire rest of the message becomes "still inside code".
    def repl_block(m):
        body = m.group(1).replace("\\", "\\\\")
        return stash("```" + body + "```")
    text = re.sub(r"```([\s\S]*?)```", repl_block, text)

    # Step 2 — inline code (single backticks, non-greedy)
    def repl_inline(m):
        body = m.group(1).replace("\\", "\\\\")
        return stash("`" + body + "`")
    text = re.sub(r"`([^`\n]+)`", repl_inline, text)

    # Step 3 — links [text](url)
    def repl_link(m):
        link_text = m.group(1)
        url = m.group(2)
        return stash(f"[{escape_md2(link_text)}]({escape_md2_url(url)})")
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", repl_link, text)

    # Step 4 — convert **bold** to MD2 *bold* (stash it so * don't get escaped)
    def repl_bold(m):
        return stash("*" + escape_md2(m.group(1)) + "*")
    text = re.sub(r"\*\*([^*\n]+)\*\*", repl_bold, text)

    # Step 5 — convert _italic_ to stash (preserve, don't escape underscores)
    def repl_italic(m):
        return stash("_" + escape_md2(m.group(1)) + "_")
    text = re.sub(r"(?<!\w)_([^_\n]+)_(?!\w)", repl_italic, text)

    # Step 6 — escape everything else
    text = escape_md2(text)

    # Step 7 — restore placeholders. They got escaped (\x00 won't be touched
    # since it's not in MD2_RESERVED, and the digits/letters are fine), but the
    # marker is intact. Walk and replace IN A FIXED-POINT LOOP because outer
    # placeholders (bold/italic) wrap inner ones (code/links) — restoring the
    # outer first re-exposes the inner marker, which we then replace on the
    # next pass. Without the loop, ` `code` ` inside `**bold**` would leak
    # the literal `\x00P0P\x00` marker into the output.
    for _ in range(10):  # safety bound, deeper nesting than this is unlikely
        changed = False
        for i, original in enumerate(placeholders):
            marker = f"\x00P{i}P\x00"
            if marker in text:
                text = text.replace(marker, original)
                changed = True
        if not changed:
            break

    return text


def split_chunks(text: str, max_len: int = MAX_CHUNK) -> list[str]:
    """Split on newline boundaries, keeping each chunk <= max_len."""
    if len(text) <= max_len:
        return [text]
    chunks = []
    while len(text) > max_len:
        # Prefer last \n\n then last \n then hard cut
        cut = text.rfind("\n\n", 0, max_len)
        if cut < max_len // 2:
            cut = text.rfind("\n", 0, max_len)
        if cut < max_len // 2:
            cut = max_len
        chunks.append(text[:cut].rstrip())
        text = text[cut:].lstrip("\n")
    if text:
        chunks.append(text)
    return chunks


def send_chunk(
    token: str, chat_id: str, text: str, parse_mode: str | None,
    reply_to: str | None,
) -> dict:
    payload = {"chat_id": chat_id, "text": text, "disable_web_page_preview": True}
    if parse_mode:
        payload["parse_mode"] = parse_mode
    if reply_to:
        payload["reply_to_message_id"] = int(reply_to)
        payload["allow_sending_without_reply"] = True

    req = urllib.request.Request(
        TG_API.format(token=token),
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return {"ok": False, "http_status": e.code, "error": body}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def main() -> int:
    p = argparse.ArgumentParser(description="Send a Telegram message with auto MD2 + split")
    p.add_argument("text", nargs="?", help="Message text. Reads stdin if omitted.")
    p.add_argument("--chat-id", help="Chat ID (default: TELEGRAM_CHAT_ID from .env)")
    p.add_argument("--reply-to", help="Reply to this message_id (threads under it)")
    p.add_argument("--plain", action="store_true",
                   help="Send as plain text (skip MD2 conversion + escaping)")
    p.add_argument("--quiet", action="store_true", help="Suppress output on success")
    args = p.parse_args()

    text = args.text if args.text is not None else sys.stdin.read()
    if not text or not text.strip():
        print("error: empty text", file=sys.stderr)
        return 1

    env = load_env()
    token = env.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = args.chat_id or env.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        print("error: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID required", file=sys.stderr)
        return 1

    if args.plain:
        chunks = split_chunks(text)
        parse_mode = None
    else:
        md2 = to_markdownv2(text)
        chunks = split_chunks(md2)
        parse_mode = "MarkdownV2"

    sent_ids = []
    for i, chunk in enumerate(chunks):
        # First chunk threads under reply_to (if set), rest don't
        reply_to = args.reply_to if i == 0 else None
        result = send_chunk(token, chat_id, chunk, parse_mode, reply_to)
        if not result.get("ok"):
            # Fall back to plain text once if it was a parse error
            if parse_mode == "MarkdownV2" and "parse" in str(result.get("error", "")).lower():
                # Log the converted text + the API error so future failures are debuggable.
                print(f"  md2 parse failed on chunk {i+1}, falling back to plain", file=sys.stderr)
                print(f"    api error: {str(result.get('error', ''))[:300]}", file=sys.stderr)
                print(f"    converted text head: {chunk[:200]!r}", file=sys.stderr)
                # Re-split the ORIGINAL text in plain mode and resend everything
                plain_chunks = split_chunks(text)
                sent_ids = []
                for j, pc in enumerate(plain_chunks):
                    rt = args.reply_to if j == 0 else None
                    r = send_chunk(token, chat_id, pc, None, rt)
                    if not r.get("ok"):
                        print(f"  plain fallback also failed: {r}", file=sys.stderr)
                        return 2
                    sent_ids.append(r["result"]["message_id"])
                break
            print(f"  send failed: {result}", file=sys.stderr)
            return 2
        sent_ids.append(result["result"]["message_id"])

    if not args.quiet:
        for mid in sent_ids:
            print(mid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
