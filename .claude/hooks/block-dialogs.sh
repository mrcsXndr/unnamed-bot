#!/usr/bin/env bash
# PreToolUse guard - hard-block interactive TUI dialogs.
#
# This bot can run as a long-lived, TG-driven / headless agent. A blocking
# dialog (AskUserQuestion, ExitPlanMode) freezes the whole loop: the TUI waits
# for a keypress that never comes over Telegram, so inbound work stalls
# indefinitely. This is belt-and-suspenders behind the settings.json `deny` rule
# - exit 2 on a PreToolUse hook BLOCKS the tool call and feeds the message back
# to the model.
#
# Scoped by the hook matcher to AskUserQuestion|ExitPlanMode, so it only fires
# for those tools. FAIL-CLOSED by design: the whole point is to refuse, so we
# always exit 2.
echo "BLOCKED: AskUserQuestion / ExitPlanMode are disabled here - a blocking TUI dialog freezes the headless/TG-driven flow (no one can answer it over Telegram). Do NOT retry. Instead: pick the sensible default and proceed, stating the choice in your reply. If you genuinely need the user's input, send a NON-blocking question via 'python tools/tg_send.py \"...\"' and continue with a reasonable default rather than waiting." >&2
exit 2
