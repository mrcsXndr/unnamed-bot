# memory/sessions/

Per-session working memory — created automatically by the session-start hook.

Each session gets a directory named by its session id containing:

- `journal.md` — the Director's Journal: findings / decisions / observations /
  questions / hypotheses / actions, appended live via
  `python tools/v2/journal.py append <session> <kind> <text>`
- `timeline.md` — the distilled narrative, built via
  `python tools/v2/timeline.py build <session>` (or the TG `/compact` command)
- `critic-<ts>.json` — per-subagent credibility envelopes

All of it is indexed by `tools/v2/recall.py` (FTS5) so any future session can
recall what was found/decided without re-reading these files.

This directory ships empty on purpose — it fills up as your bot works.
