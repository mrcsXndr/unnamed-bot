#!/usr/bin/env python3
"""
transcribe.py — transcribe a voice/audio file via Groq Whisper.

Built specifically to handle Telegram voice messages from the channel plugin
which arrive as .oga files with audio/ogg mime — Groq's filename-based filetype
check rejects .oga even though the content is identical to .ogg, so we always
override the filename in the multipart form to .ogg.

Also requires a browser-style User-Agent header — Cloudflare in front of
Groq returns 403 (error code 1010) for plain Python urllib UAs.

Usage:
    python tools/transcribe.py <path-to-audio-file>

Reads GROQ_API_KEY from the project .env. Prints the transcription to stdout.
Exit non-zero on failure with a clear error.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / ".env"
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
MODEL = "whisper-large-v3-turbo"  # faster, similar quality for short clips
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"


def load_env_var(name: str) -> str:
    if not ENV_FILE.exists():
        sys.exit(f"error: {ENV_FILE} not found")
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if k.strip() == name:
            return v.strip()
    sys.exit(f"error: {name} not in {ENV_FILE}")


def transcribe(path: Path, api_key: str) -> str:
    if not path.exists():
        sys.exit(f"error: {path} does not exist")

    data = path.read_bytes()
    boundary = f"----PythonBoundary{int(time.time() * 1000)}"

    # Telegram voice files arrive as .oga; Groq's filetype check rejects .oga
    # even though the bytes are valid OGG. Override the filename in the form.
    forced_filename = "voice.ogg"

    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{forced_filename}"\r\n'
        f"Content-Type: audio/ogg\r\n\r\n"
    ).encode("utf-8")
    body += data
    body += (
        f"\r\n--{boundary}\r\n"
        f'Content-Disposition: form-data; name="model"\r\n\r\n'
        f"{MODEL}\r\n"
        f"--{boundary}--\r\n"
    ).encode("utf-8")

    req = urllib.request.Request(
        GROQ_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read())
            return result.get("text", "").strip()
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")
        sys.exit(f"error: HTTP {e.code} from Groq: {body_text[:500]}")
    except Exception as e:
        sys.exit(f"error: {type(e).__name__}: {e}")


def main():
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <path-to-audio-file>")
    path = Path(sys.argv[1])
    api_key = load_env_var("GROQ_API_KEY")
    text = transcribe(path, api_key)
    if not text:
        sys.exit("error: empty transcription")
    print(text)


if __name__ == "__main__":
    main()
