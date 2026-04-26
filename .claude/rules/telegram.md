# Telegram Bridge

The repo ships a send-side Telegram bridge (`tools/tg_send*.py`). Reading incoming messages is **not** included here — that requires either polling the Telegram Bot API yourself or running a Claude Code channel plugin.

## Setup
- Create a bot with [@BotFather](https://t.me/botfather) → grab the token.
- Send a message to your bot, then visit `https://api.telegram.org/bot<TOKEN>/getUpdates` to find your chat ID.
- Add to `.env`:
  ```
  TELEGRAM_BOT_TOKEN=...
  TELEGRAM_CHAT_ID=...
  ```

## Sending
- **For formatted messages, always use `python tools/tg_send.py "..."`.** It auto-converts CommonMark to MarkdownV2, escapes every reserved character per Telegram's spec, splits at 4000 chars on newline boundaries (4096 is the hard cap), and falls back to plain text on parse errors.
- For media: `tg_send_photo.py`, `tg_send_document.py`, `tg_send_video.py`. All accept a path + optional caption.
- The default chat ID comes from `.env`; override per-call with `--chat-id <id>`.
- Quote-reply with `--reply-to <message-id>`.

## Receiving (optional)
If you want the bot to handle inbound messages, install a Claude Code channel plugin like `claude-plugins-official:telegram` and launch with `claude --channels plugin:telegram@claude-plugins-official`. Inbound messages arrive as `<channel source="telegram" …>` events.

## Voice notes
Telegram voice messages arrive as `.oga` files. `tools/transcribe.py <path>` runs them through Groq Whisper and returns a plain-text transcription. Requires `GROQ_API_KEY` in `.env`.
