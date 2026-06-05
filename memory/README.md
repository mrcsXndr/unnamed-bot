# Memory

This directory is the bot's **long-term, cross-session memory**. Unlike the
`context/` docs (facts about you and your projects), `memory/` holds *learned
behaviour* — preferences, corrections, and conventions the bot picks up as you
work together. It survives compaction, restarts, and (with the sync hook) moves
between your machines.

## How it works

- The bot writes small, single-topic Markdown notes here as it learns how you
  like things done ("always confirm before sending email", "I prefer bullet
  points", "deploy to staging first").
- `MEMORY.md` is the **index** — a short list linking to each note so the bot
  can scan what it knows without reading every file.
- At session start the bot reads the index; it pulls in individual notes only
  when relevant.

## File conventions

| Prefix | Meaning |
|---|---|
| `personality.md` | The bot's character / voice profile |
| `feedback_*.md` | A preference or correction you gave the bot |
| `project_*.md` | A durable fact about how a specific project works |
| `reference_*.md` | A reusable reference (account names, conventions, setup quirks) |

Each note starts with a small front-matter block:

```markdown
---
name: Short title
description: One-line summary that goes in the index
type: feedback | project | reference | user
---

The actual note — keep it short and specific.
```

## Cross-machine sync (optional)

`tools/memory-sync-hook.cjs` (wired in `.claude/settings.json`) auto-commits and
pushes `memory/` to your git remote on session end, and pulls on session start —
so your bot's learned knowledge follows you between computers. It never
force-pushes; conflicts are flagged in `MEMORY_SYNC_CONFLICT.md` for safe manual
resolution.

## Important

- **Keep secrets OUT of `memory/`.** It is committed to git and pushed to your
  remote. API keys, tokens, and passwords belong in `.env` (gitignored).
- Memory is committed to the repo on purpose — that is what makes it portable.
  If your repo is public, treat every memory note as public.
- Subdirectories `projects/` and `sessions/` hold per-project state files and
  auto-generated session snapshots respectively (written by `state_track.py`
  and `session_summarize.py`).
