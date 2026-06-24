# v2 Architecture — Three Channels + Memory Loop + Tiered Agents

Inspired by Slack's agent-context pattern and holographic-memory ("Hermes")
patterns. Goals: cut token spend on a typical day, carry durable memory across
sessions WITHOUT re-reading transcripts, and dispatch each task to the
right-priced model so you never burn the top tier on a one-shot lookup or spin a
cheap model on architecture.

## The Three Channels

| Channel | Purpose | Storage | Lifetime |
|---|---|---|---|
| **Director's Journal** | Live structured working memory. Findings / decisions / open questions / hypotheses / observations / actions captured AS THEY HAPPEN. | `memory/sessions/<id>/journal.md` | per session |
| **Critic's Timeline** | Distilled chronological narrative built from the journal. | `memory/sessions/<id>/timeline.md` | per session, then promoted to `memory/timelines/<week>.md` |
| **Critic's Review** | Per-subagent credibility-graded findings (manual / on-demand). | `memory/sessions/<id>/critic-<ts>.json` | per subagent return |

The Director (main thread) is the orchestrator: it holds long-running plan
state, dispatches to subagents, and writes the Journal. Subagent transcripts stay
OUT of the main thread — that is how main context is preserved.

## The Tiered Agent Set (`.claude/agents/`)

| Agent | Model | When |
|---|---|---|
| `planner` | Opus | Architecture, multi-file refactor design, deep planning |
| `senior-coder` | Opus | Architecture-aware multi-file code, deep-thinking changes |
| `coder` | Sonnet | Single-file edits, mechanical work, per-item tasks |
| `one-shot` | Sonnet | Factual lookups, status pings, single-tool answers |
| `critic` | Sonnet | Credibility scoring of subagent output (on-demand) |
| `fable` | Fable | Top-tier generalist (PLAN/IMPLEMENT/REVIEW) for the hardest plans, deep reviews, complex/creative coding. When Fable is unavailable, this work falls back to the Opus tiers. |

The default model for the main thread is set in `.claude/settings.json`.

## Hermes memory loop (the durable patterns)

- **#1 cross-session recall** — `tools/v2/recall.py` (FTS5 over every
  `memory/sessions/*/journal.md` + promoted timelines), refreshed at session
  start. Zero-LLM, ~ms recall: `recall.py search "<query>" [--min-trust X]`.
- **#2 multi-writer safety** — `tools/v2/safe_write.py` (cross-platform lock +
  atomic rename + drift guard). The substrate journal/salvage writes go through.
- **#3 memory budget header** — emitted by the SessionStart hook so the assistant
  SEES how full MEMORY.md / the journal are and self-consolidates before bloat.
- **#4 trust scoring + asymmetric feedback + retrieval decay** — in `recall.py`
  (`search` ranks by FTS5 rank THEN `trust_score DESC`; `feedback <id>
  helpful|unhelpful` nudges +0.05 / −0.10 clamped). Wrong facts decay out.
- **#5 pre-compaction extraction** — `tools/v2/precompact_extract.py` on the
  PreCompact hook salvages durable `decision`/`finding` entries before context
  is discarded; `tools/v2/precompact_timeline.py` rebuilds the timeline so a
  forced-fresh restart re-injects fresh context.

## Hook order

```
session-start-context.sh  creates journal + injects journal/timeline + budget into the system prompt
        |
        v
user-prompt-submit.sh     large-paste guard (stash + redirect), else pass through
        |
        v
main thread or subagent runs
        |
        v
SubagentStop -> post-subagent.sh   appends a journal note that a subagent returned
        |
        v
PreCompact -> precompact_extract.py (salvage) + precompact_timeline.py (rebuild)
        |
        v
Stop hooks (memory-sync, play-sound, session-debrief, session_summarize, state_track, auto-commit, cost_meter)
```

All hooks are STRICTLY FAIL-OPEN: each swallows its own errors and exits 0 so
session start/stop is never broken.

## When to write to the journal MANUALLY (from the main thread)

- Significant decisions ("we're going with X, not Y")
- Open questions that block forward motion
- Hypotheses to test next session
- Blockers (with owner + ETA)

```bash
PYTHONIOENCODING=utf-8 python tools/v2/journal.py append "$SESSION_ID" decision "<the decision>"
```

Kinds (6 entry types): `finding`, `decision`, `observation`, `question`,
`hypothesis`, `action`. Use `observation` for raw tool/file output worth
remembering, `finding` for synthesised conclusions, `decision` for chosen-path
commitments, `question` for blockers, `hypothesis` for "next session try X",
`action` for things performed.

## Critic flow

The critic is a Claude Code subagent (`.claude/agents/critic.md`). The
`SubagentStop` hook (`post-subagent.sh`) writes a cheap journal note only — it
does NOT auto-grade (auto-grading every subagent return is pure cost with no
payoff). For an actual credibility grade, dispatch the `critic` subagent
deliberately, or run a `/critic` slash command if you add one.

## Cost meter

`tools/v2/cost_meter.py` runs on the `Stop` hook and appends one row per session
to `memory/metrics/sessions.csv`:
`session_id,ts_start,ts_end,project,input_tok,output_tok,cache_read_tok,
cache_creation_tok,subagent_count,model_mix,usd_est`. Pricing mirrors
`tools/statusline.js`. `tools/v2/cost_report.py` rolls the CSV up
(`--days N`, `--tg`).

## Telegram single-poller invariant + auto-heal

The TG Bot API allows only ONE `getUpdates` long-poller per bot token. If a
second instance launches with `--channels plugin:telegram@...` pointed at the
same bot, it steals the poll slot; the first poller then 409s and PERMANENTLY
gives up while its process stays alive — so OUTBOUND (`tg_send.py`) keeps working
but INBOUND silently dies.

Two-layer fix:
- **Owner-lock (prevention)** — `scripts/launch.ps1` claims
  `.claude/.tg_owner.lock` (PID + ts) before launch and only passes `--channels`
  if no LIVE foreign owner holds it (live owner PID AND live `bot.pid`). Stops a
  second instance from dual-polling.
- **Watchdog (auto-heal) — BRIDGE-FIRST** — `tools/v2/tg_watchdog.py` probes the
  slot via the getUpdates-409 trick (409=ALIVE; all-200 across 8 spaced probes =
  DEAD; other=UNKNOWN → no action). On confirmed DEAD it heals bridge-first:
  1. **Bridge kick** (works even while the session is BUSY) — kill JUST the
     poller subprocess (`~/.claude/channels/telegram/bot.pid`); the channel-plugin
     host stays loaded and respawns a fresh poller that re-claims the slot. The
     conversation + in-flight work are untouched. Name-guarded (`bun`/`node`)
     against PID reuse; re-probes after `KICK_RESETTLE_S` to confirm.
  2. **Full restart** (fallback) — only if the kick did NOT restore polling, fall
     back to the idle-gated detached session restart (reuses `update_restart.py`
     machinery). Backoff: 3 heals / 30 min, logged to
     `memory/metrics/tg_heals.log`. STRICTLY FAIL-OPEN.
  Register via `scripts/register-tg-watchdog.ps1` (prints the schtasks line by
  default; `-Confirm` actually creates the task).

## Auto-start daemon + supervisor

- **`scripts/bot-supervisor.ps1`** — single authority for "exactly one healthy
  bot is running." Resolves bot liveness from the owner-lock (launcher pwsh PID +
  its `claude.exe` child) and the poller via `tg_watchdog.py --probe-only`.
  Decisions: no bot process → COLD-START; bot alive + poller DEAD → RESTART (via
  `restart-bot.ps1`); bot alive + poller ALIVE/UNKNOWN → no-op. Single-instance
  via a `Global\AssistantBotSupervisor` mutex; start-backoff (MaxStartsPerWindow /
  WindowMin); STRICTLY FAIL-OPEN. `--probe-only` / `--dry-run`. Cold-start must
  NOT go through `restart-bot -OldPid 0` (PID 0 is the System Idle Process and
  reads "alive").
- **`scripts/register-bot-supervisor.ps1`** — installs the `AssistantBot-Supervisor`
  scheduled task with TWO triggers: At Logon (boot daemon, cold-start) and every
  N minutes (liveness). Runs in the INTERACTIVE user session so the launched WT
  window is visible; the supervisor itself runs hidden (via a generated VBS shim
  to avoid a console flash). `-Unregister` removes it.

### Resumability across restarts

- **`--continue` restart** reuses the SAME `session_id` → journal/timeline
  re-inject the same thread cleanly. **Lossless.**
- **Forced-FRESH restart** (supervisor cold-start + `restart-bot` default, chosen
  to dodge the blocking aged-session resume picker) starts a NEW `session_id`.
  The thread is RECONSTRUCTED — not resumed by id — because the SessionStart hook
  re-injects the newest prior `timeline.md` + `journal.md` tail. Lossy-by-design:
  in-flight TODO state not yet journaled is lost. Mitigation: journal
  aggressively + both PreCompact hooks fire before a compact.

## Self-update + restart

`tools/v2/update_restart.py` runs `claude update`, and ONLY if a new version
landed, posts a notice, spawns `restart-bot.ps1` DETACHED (passing the live
claude PID), and terminates the live process so the relaunch resumes the
now-single conversation. Modes: default flow, `--dry-run`, `--check-only`,
`--restart-only` (smoke test the restart dance), `--auto` (gated autonomous —
gates: not-checked-today, update-available, session-idle). The `--auto` gate
logic exists but is NOT auto-wired to any hook/timer; invoke it deliberately.

## Memory sanitization before injection (block-on-poison)

The SessionStart hook injects journal / timeline / last-session into the system
prompt; those channels can carry pasted content = an injection persistence
vector. Each chunk passes through `tools/v2/sanitize_chunk.py` (thin gate over
`tools/sanitize.py`): HIGH/CRITICAL risk → replaced with a `[BLOCKED: … ]`
marker; otherwise the cleaned chunk is injected. FAIL-OPEN: if sanitize can't
run, the raw chunk is injected (never breaks session start).

## Marker / state files (gitignored)

- `.claude/.current_session_id` — the live session id, written by SessionStart.
- `.claude/.bot_v2_state.json` — authoritative PID record (launcher + supervisor).
- `.claude/.tg_owner.lock` — TG single-poller owner-lock.
- `.claude/.bot_fresh_restart` — one-shot marker; forces a FRESH relaunch, deleted on launch.
- `.claude/.bot_v2_update_stamp` — daily `claude update` check stamp.

## Env vars (all optional, sensible defaults)

- `BOT_V2_LOCK_TIMEOUT` (safe_write lock timeout, default 10s)
- `BOT_V2_DISTILL_MODEL` / `BOT_V2_DISTILL_TIMEOUT` (timeline distill)
- `BOT_V2_WEEKLY_GATE_H` (min hours between weekly distills, default 6)
- `BOT_V2_JOURNAL_HEAD_BYTES` (journal load cap at session start, default 20000)
- `BOT_V2_SIZE_THRESHOLD` (inbound large-paste guard threshold, default 50000)
- `BOT_V2_MAX_CONTEXT` (status footer context denominator, default 500000)
- `BOT_IDLE_MIN` (update_restart idle gate, default 5m)
- `BOT_PROJECT_SLUG` (override the derived Claude Code project slug)
- `BOT_PYTHON` (explicit python interpreter for the PS scripts)
- `BOT_SECRETS_DIR` / `SYNC_DRIVE_PATH` (secrets/settings backup folder)
