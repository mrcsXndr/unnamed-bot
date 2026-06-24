# Reference: local setup notes

> Example reference note. Replace the placeholders with your own environment
> facts. Notes in `memory/reference/` are reusable setup quirks, account names,
> and conventions the bot should recall without re-deriving them.

- **Secrets/backup folder**: set `BOT_SECRETS_DIR` (e.g. `$USERPROFILE/AssistantBot-secrets`).
- **Python**: discovered from PATH; override with `BOT_PYTHON` if needed.
- **Telegram**: bot token in the repo `.env` as `TELEGRAM_BOT_TOKEN`; the
  channel plugin's own state `.env` lives under `~/.claude/plugins/...` (the
  launcher patches it on Windows).
- **Cloud accounts / repos**: list which account to use for which project here.
