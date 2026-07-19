# v2 Architecture — Three Channels + Memory Loop + Tiered Agents

Goal: cut token spend dramatically on a typical day, carry durable memory
across sessions WITHOUT re-reading transcripts, and dispatch each task to the
right-priced model so you never burn a top-tier model on a one-shot lookup.

## The Three Channels

| Channel | Purpose | Storage | Lifetime |
|---|---|---|---|
| **Director's Journal** | Live structured working memory. Findings / decisions / open questions / hypotheses / actions captured AS THEY HAPPEN. | `memory/sessions/<id>/journal.md` | per session |
| **Timeline** | Distilled chronological narrative built periodically from the journal. | `memory/sessions/<id>/timeline.md` | per session |
| **Critic envelope** | Per-subagent credibility JSON (zero-LLM by default). | `memory/sessions/<id>/critic-<ts>.json` | per subagent return |

The main thread (the **Director**) writes journal entries **liberally**:
journal + timeline replace re-reading message history after compaction. If you
don't write it down, it's gone.

```bash
PYTHONIOENCODING=utf-8 python tools/v2/journal.py append "$SESSION_ID" decision "switching deploys to dev-only by default"
```

Six entry kinds: `finding` (synthesised conclusions), `decision` (chosen-path
commitments), `observation` (raw tool/file output worth remembering),
`question` (blockers needing the user), `hypothesis` ("next session try X"),
`action` (things performed).

## Memory loop (all zero- or low-LLM)

- **#1 Cross-session recall** — `tools/v2/recall.py`: FTS5 index over ALL
  session journals + timelines, refreshed at session start. To recall what any
  past session found/decided WITHOUT re-reading journals:
  `python tools/v2/recall.py search "<query>" [--min-trust X]`.
- **#2 Multi-writer safety** — `tools/v2/safe_write.py` (lock + atomic rename)
  guards the shared stores (commitments, recall feedback).
- **#3 Memory budget header** — session-start emits `[memory: …] [journal: …]`
  usage lines so the Director self-consolidates before they bloat.
- **#4 Trust scoring** — each recalled fact carries `trust_score` (default
  0.5). When a fact proves wrong: `python tools/v2/recall.py feedback <id>
  unhelpful` (−0.10; `helpful` +0.05) and it decays out of future recall.
- **#5 Pre-compaction extraction** — `tools/v2/precompact_extract.py` +
  `precompact_timeline.py` on the `PreCompact` hook salvage durable
  decisions/findings before context is discarded.

## Commitments loop

Due-dated follow-ups that resurface automatically instead of relying on the
user to re-ask. `tools/v2/commitments.py` over `memory/commitments.json`:
`add "<text>" [--due <ISO|Nd|Nh|Nm|tomorrow>]`, `list [--open]`, `done <id>`,
`surface` (printed at session start). On Windows with the supervisor
installed, `commitments.py heartbeat` runs every tick and TG-alerts due items
(cooldown `BOT_HEARTBEAT_COOLDOWN_H`, default 6h). Notify-only by design.

## Cost meter

`tools/v2/cost_meter.py` runs on the `Stop` hook, prices the session's tokens
from its transcript JSONL, and appends one row to
`memory/metrics/sessions.csv`. `tools/v2/cost_report.py` (and the TG `/costs`
command) roll it up. `tools/infra/statusline.js` shows a live lifetime total.

## Tiered subagents (`.claude/agents/`)

| Agent | Default model | When |
|---|---|---|
| **Director** (main thread) | your default | Always. Orchestrator: holds plan state, reads journal+timeline, dispatches subagents, replies on TG. |
| `planner` | opus | Architecture, multi-file refactor design, trade-offs that cost hours if wrong |
| `senior-coder` | opus | Plan locked, implementation needs top-tier care (cross-layer bugs, new abstractions) |
| `coder` | sonnet | Mechanical edits, single-file fixes, per-item batches — spawn freely, in parallel |
| `one-shot` | sonnet | Factual lookups, status checks, single-tool answers (≤200 words) |
| `critic` | sonnet | Credibility-score a subagent result on demand (5-band rubric, JSON envelope) |
| `fable` | fable | The hardest work — most ambiguous architecture, deepest cross-layer implementation, rigorous reviews, creative/game builds. Top tier, top cost; reserve for where model strength changes the outcome. Runs in PLAN/IMPLEMENT/REVIEW mode. |

Models are documented defaults — edit the `model:` frontmatter in
`.claude/agents/*.md` to taste (e.g. if you don't have Fable access, drop it or
point it at your best available model). When in doubt: `planner` first to scope,
then `senior-coder` or a fan-out of `coder`s, `critic` to verify.

**Default to subagents for anything >1 file or >3 grep-passes.** Subagent
transcripts stay out of the main thread; each finds its own context; long
sessions stay viable because the journal is the long-term memory.

## Hook order

```
SessionStart  -> session-start-v2.sh     recall index refresh + journal create +
                                         journal/timeline/budget/commitments injection
UserPromptSubmit -> user-prompt-submit.sh  TG slash-command intercept + large-paste guard
   (main thread or subagent runs)
SubagentStop  -> post-subagent.sh        zero-LLM critic envelope + journal note
PreCompact    -> precompact_extract.py + precompact_timeline.py   salvage
Stop          -> memory-sync (opt-in), play-sound, session-debrief (opt-in),
                 auto-commit (opt-in), cost_meter.py
```

Every hook is STRICTLY FAIL-OPEN: it swallows its own errors and exits 0 so
session start/stop never breaks.

## TG slash commands (auto-intercepted)

| Command | Effect |
|---|---|
| `/status` | Single-line status footer (cwd, git, ctx, sess, TG) |
| `/journal [n]` | Last N journal entries (default 30) |
| `/timeline` | Current distilled timeline |
| `/compact` | Distill journal → timeline + write checkpoint marker |
| `/tasks` | Top 30 rows of the task board sheet (needs TASK_BOARD_SHEET_ID) |
| `/costs [Nd]` | Per-session cost rollup from sessions.csv |
| `/update` | Update Claude Code; self-restart if a new version landed (`dry-run`/`check` are safe) |
| `/help` | List commands |

Add new commands in `tools/v2/tg_commands.py` (HANDLERS dict).

## Critic flow

The automatic per-subagent LLM scoring is deliberately NOT wired — the
`SubagentStop` hook writes a cheap ZERO-LLM envelope only. For an actual
credibility grade, invoke deliberately: `Agent(subagent_type="critic", ...)`
or the `/critic <result-file>` command. A gated, deliberate critic is the
defensible version; auto-firing on every subagent return is pure cost.

## Long-running sessions are the goal

With journal + timeline carrying state across compaction, there's rarely a
reason to start fresh. Default to `--continue` (the launch scripts do). Fresh
session only for: hard migrations, intentional context reset, or debugging the
harness itself. A **supervisor RESTART** of a recently-alive session relaunches
with `--continue` (a just-killed session is not aged, so it resumes cleanly and
its working context is preserved — never force FRESH on a live session's
restart). Only a **cold-start** (after reboot/crash) forces FRESH via the
one-shot `.claude/.bot_fresh_restart` marker, since an aged session would hit
Claude Code's resume picker that blocks headless loops; journal/timeline/recall
make that cold FRESH ~lossless.

## Windows resilience layer (opt-in; see docs/SETUP.md)

- **Supervisor** (`scripts/supervisor.ps1` + `register-supervisor.ps1`) —
  scheduled task, at-logon + every 3 min: exactly one healthy instance,
  cold-start after reboot/crash, poller heal, commitments heartbeat, optional
  monitors. Mutex-serialised, start-capped, strictly fail-open.
- **TG watchdog** (`tools/v2/tg_watchdog.py` + `register-tg-watchdog.ps1`) —
  standalone poller auto-heal for setups without the full supervisor. Probes
  the getUpdates slot (409=ALIVE trick); on confirmed-dead + idle session,
  triggers a detached restart. 3-heals-per-30-min backoff.
- **Self-restart** (`scripts/restart-bot.ps1`, used by `/update` and the
  supervisor) — wait-for-old-PID-then-relaunch, so two instances never attach
  the same conversation.

**TG single-poller invariant + enablement model.** The Telegram Bot API allows
only ONE `getUpdates` long-poller per bot token; a second `claude` launched with
`--channels` on the same token SIGTERM-steals the slot and the first poller then
409s into a permanent dead state (outbound `tg_send.py` keeps working, inbound
silently dies). Two rules keep exactly one poller:
- **Enablement lives ONLY in the tracked `.claude/tg-enable.settings.json`**,
  which the launcher passes explicitly via `claude --settings … --channels …` and
  ONLY when it owns the poller lock (`.claude/.tg_owner.lock`). NEVER put
  `enabledPlugins` for telegram in `.claude/settings.json` or
  `settings.local.json` (or global): a settings-file enablement is auto-loaded by
  EVERY `claude` launch in this repo cwd — plain `claude`, headless `--print`
  spawns — each starting a bridge that steals the slot.
- **Every headless/spawned `claude` passes `--setting-sources user`** (defense in
  depth) so it can't load the repo-local plugin enablement even by accident.
- The watchdog additionally detects a STOLEN slot (409 held by a foreign local
  claude, not our tree) and heals it on the same idle-gated restart path.

## Token-saving discipline (non-negotiable)

1. **Never paste full file contents into chat.** Use `Read` and reference the path.
2. **Use subagents for anything >1 file or >3 grep-passes.**
3. **Match the agent to the task** — the agent descriptions encode the rules.
4. **Append to the journal aggressively** — entries are 1-line and replace
   re-explaining context next session.
