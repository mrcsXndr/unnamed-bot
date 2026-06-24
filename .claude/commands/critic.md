# /critic — manual credibility pass on a subagent result

Use this slash command when:
- You want to score a specific subagent result on demand
- You want a credibility check on something you wrote yourself

## What it does

Invokes the `critic` subagent (Sonnet) to score the factual claims in a result
against its original brief and any cited evidence.

## Usage

`/critic <path-to-result-file>` — scores the file's content against any cited
evidence and writes a JSON to `memory/sessions/<id>/critic-<ts>.json`.

If no path is given, scores the most recent subagent result in the current session.

## Implementation

1. Resolve the result file: argument OR most recent in `memory/sessions/<session-id>/`.
2. Read the result file content.
3. Invoke `Agent(subagent_type="critic", prompt="Score this result for credibility:\n\n<content>")`.
4. Parse the JSON the critic returns.
5. Write to `memory/sessions/<session-id>/critic-<timestamp>.json`.
6. Echo the overall_score + top red_flags inline.
