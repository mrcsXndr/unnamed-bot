#!/usr/bin/env python3
"""
transcribe.py — transcribe a voice/audio file locally with faster-whisper.

Telegram voice notes arrive as .oga (Opus in Ogg). faster-whisper decodes
through its bundled PyAV, so no ffmpeg binary is required for them; if a
decode does fail for lack of a codec, the message below says how to get one.

Usage:
    python tools/tg/transcribe.py <path-to-audio-file> [--model small] [--language xx]

Prints the transcript to stdout (empty output = nothing recognisable, e.g.
silence — that is a pass, not an error). Model weights are cached under
~/.cache/huggingface on first use (~500MB for `small`).

Exit codes:
    0  transcribed (possibly empty)
    1  bad path / decode failure
    2  faster-whisper not installed (prints the pip line — never crashes the bot)
"""

import argparse
import os
import sys
from pathlib import Path

# Windows without Developer Mode: the HF cache falls back to copies and warns
# on every run. Harmless, and the warning would otherwise land in the bot's
# stderr each voice note.
os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")

AUDIO_EXTS = (".ogg", ".oga", ".opus", ".mp3", ".m4a", ".wav", ".flac", ".webm", ".mp4")


def main() -> int:
    p = argparse.ArgumentParser(description="Local Whisper transcription (faster-whisper, CPU int8)")
    p.add_argument("path")
    p.add_argument("--model", default="small", help="whisper size: tiny/base/small/medium (default small)")
    p.add_argument("--language", default=None, help="ISO code to skip auto-detect (e.g. en, sv)")
    args = p.parse_args()

    path = Path(args.path)
    if not path.exists():
        print(f"error: {path} does not exist", file=sys.stderr)
        return 1

    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print("faster-whisper is not installed. Install it with:\n"
              "    pip install faster-whisper\n"
              "then re-run this command.", file=sys.stderr)
        return 2

    try:
        model = WhisperModel(args.model, device="cpu", compute_type="int8")
        segments, _info = model.transcribe(str(path), language=args.language, vad_filter=True)
        text = " ".join(s.text.strip() for s in segments).strip()
    except Exception as exc:
        msg = str(exc)
        print(f"error: transcription failed: {type(exc).__name__}: {msg[:300]}", file=sys.stderr)
        if path.suffix.lower() in AUDIO_EXTS and ("decod" in msg.lower() or "av" in msg.lower()):
            print("If this is a codec/decode problem, install ffmpeg and convert first:\n"
                  "    winget install --id Gyan.FFmpeg -e\n"
                  f"    ffmpeg -i \"{path}\" -ar 16000 -ac 1 \"{path.with_suffix('.wav')}\"",
                  file=sys.stderr)
        return 1

    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
