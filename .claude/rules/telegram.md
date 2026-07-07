# Telegram Bridge

Two halves:
- **Inbound** — the official channel plugin (`telegram@claude-plugins-official`).
  Launch with `--channels plugin:telegram@claude-plugins-official` (the launch
  scripts do this automatically when a token is configured). Messages arrive as
  `<channel source="telegram" chat_id="..." message_id="...">` events.
- **Outbound** — `tools/tg/tg_send.py` and the media senders. Prefer these over
  the plugin's `reply` tool for anything formatted.

## Setup
- Create a bot with [@BotFather](https://t.me/botfather) → grab the token.
- Message your bot once, then visit
  `https://api.telegram.org/bot<TOKEN>/getUpdates` to find your chat ID.
- The setup wizard (`scripts/setup`) writes both into `.env` and the plugin's
  state dir. Pairing is one-time: `/telegram:access pair <code>`.

## Sending
- **For formatted messages, always use `python tools/tg/tg_send.py "natural
  CommonMark"`.** It converts to Telegram HTML, escapes reserved chars, splits
  at 4000 chars on newline boundaries, and falls back to plain text on parse
  errors. Default chat id comes from `.env`; override with `--chat-id`.
- **A status footer is appended automatically** to every send (cwd, git branch,
  session id, context %, TG health). Disable per-message with `--no-status` or
  globally with `BOT_TG_STATUS=0`.
- Media: `tools/tg/tg_send_photo.py`, `tg_send_document.py`, `tg_send_video.py`
  — path + optional caption.
- Quote-reply with `--reply-to <message-id>` (use the inbound `message_id`).
- Keep replies mobile-concise.

## Director ↔ Telegram orchestration
You (the main thread) are the only thing that talks to Telegram. For every
inbound message:
1. **Ack first.** 1-line reply via `tg_send.py` ("on it", "checking") BEFORE
   dispatching work. Silent gaps feel unresponsive. (Tasks under ~2s can send
   ack+result combined.)
2. **Dispatch** real work to a subagent when it's >1 file or >3 grep-passes.
3. **Synthesize**: journal the outcome, then reply on TG with the answer.
4. The footer is automatic — don't append your own status line.

## Slash commands (auto-intercepted)
Inbound TG messages starting with `/` are handled by `tools/v2/tg_commands.py`
via the user-prompt-submit hook — they never reach the main thread. See
`.claude/rules/v2-architecture.md` for the command table. Add new commands in
the HANDLERS dict.

## Single-poller invariant
The TG Bot API allows only ONE `getUpdates` long-poller per bot token. A second
Claude instance launching with `--channels` for the same bot steals the slot
and the first poller dies permanently (409) while outbound keeps working — so
inbound silently stops. The launcher's owner-lock prevents this; the
supervisor/watchdog (Windows, opt-in) auto-heals it.

## Voice notes
Telegram voice messages arrive as `.oga` files. `python tools/tg/transcribe.py
<path>` runs them through Groq Whisper (needs `GROQ_API_KEY` in `.env`).
