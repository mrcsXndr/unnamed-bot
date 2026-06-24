---
paths: []
---

# Subagent Orchestration Doctrine

Director orchestrates; subagents do the work. Dispatch teams by default, preserve main context.

## Default to dispatching subagents for non-trivial work
Director is the orchestrator: holds plan state, writes the Journal, dispatches. Subagent transcripts stay OUT of the main thread — that's how main context is preserved.

## Dispatch threshold
Use a subagent for anything touching > 1 file, > 3 grep-passes, or any multi-step research/build. Single-fact lookups where you already know the location: do directly.

## Dispatch teams, fan out in parallel
Non-trivial work → send multiple independent subagents in ONE message so they run concurrently. Parallel fan-out is the default for independent workstreams (e.g. review N areas at once).

## Match the agent to the task
(See `.claude/rules/v2-architecture.md` + `.claude/agents/`.)
- `planner` / `senior-coder` (Opus) → architecture, deep multi-file work
- `coder` / `one-shot` (Sonnet) → single-file, mechanical, lookup
- `fable` → hardest plans/reviews
- `critic` → credibility-grading

## Verify consequential work with a critic pass
Auto-critic scoring is RETIRED (cost). Director must DELIBERATELY dispatch a `critic` subagent (or `/critic`) to verify subagent output before acting on anything consequential — external writes, "done" claims, security-sensitive conclusions.

## Preserve main context
Relay only the subagent's conclusion into the main thread. Don't re-read what a subagent already read. Append durable decisions/findings to the Journal.
