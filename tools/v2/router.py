#!/usr/bin/env python3
"""Router — pre-prompt classifier.

Decides whether an inbound user prompt is:
  - one-shot               (small isolated task; route to subagent)
  - multi-step-research    (needs main-thread context; do not route)
  - multi-step-build       (needs main-thread context; do not route)
  - conversation           (chat / status; do not route)
  - clarify                (ambiguous — Director should ask numbered options
                            via TG before dispatching; karpathy principle 1)

Phase: 1 (heuristic). Deterministic regex/keyword classifier so the
hook can ship before claude-haiku is wired in (Phase 3).

Output contract
---------------
{
  "class": "one-shot" | "multi-step-research" | "multi-step-build" | "conversation",
  "confidence": 0.0..1.0,
  "reasoning": "<short>",
  "phase": 1
}

CLI
---
router classify <prompt_text>
echo "<prompt>" | router classify -

Exit 0 always (errors fall back to "conversation" with low confidence —
hooks must fail-open).
"""
from __future__ import annotations

import json
import re
import sys

# Keywords that bias toward each class. Order matters: earlier = stronger.

ONE_SHOT_VERBS = {
    "what", "who", "when", "where", "which", "how many", "show me",
    "list", "find", "lookup", "look up", "check", "status", "is",
    "are", "do i have", "any", "remind", "fetch", "get", "open",
    "send", "tell", "ack", "ping",
}

BUILD_VERBS = {
    "build", "implement", "scaffold", "refactor", "ship", "deploy",
    "fix", "patch", "rewrite", "migrate", "create", "add a", "set up",
    "wire", "integrate", "port", "rename", "extract",
}

RESEARCH_VERBS = {
    "research", "investigate", "audit", "review", "analyse", "analyze",
    "compare", "evaluate", "assess", "explore", "map out", "trace",
    "diagnose", "root cause", "explain why", "deep dive",
}

CONVERSATION_HINTS = {
    "thanks", "ok", "cool", "lol", "nice", "good morning", "morning",
    "evening", "gn", "later", "btw", "fyi", "noted",
}

# Ambiguity signals — prompts that suggest 2+ valid interpretations.
# Karpathy principle 1: "present multiple interpretations". Director
# should ask before dispatching, not silently best-guess.
CLARIFY_SIGNALS = [
    r"\bshould (?:i|we|it)\b",
    r"\b(?:or|vs\.?|versus)\b",
    r"\bwhich(?:\s+(?:is|one|approach|way))\b",
    r"\bwhat's better\b",
    r"\bwhat do you think\b",
    r"\bthoughts on\b",
    r"\beither\b.*\bor\b",
    r"\bbetween\b.*\band\b",
    r"\b(?:advise|advice)\b",
    r"\b(?:option a|option b|option 1|option 2)\b",
]
CLARIFY_RE = re.compile("|".join(CLARIFY_SIGNALS), re.IGNORECASE)


def _has_any(text: str, vocab: set[str]) -> bool:
    return any(v in text for v in vocab)


def classify(prompt: str) -> dict:
    p = prompt.strip()
    if not p:
        return {
            "class": "conversation",
            "confidence": 0.3,
            "reasoning": "empty prompt",
            "phase": 1,
        }

    p_low = p.lower()
    word_count = len(re.findall(r"\w+", p_low))
    line_count = p_low.count("\n") + 1
    has_question_mark = "?" in p_low
    has_code_fence = "```" in p_low or p_low.count("`") >= 2

    # Conversation short-circuits — very short, no verbs, conversational
    if word_count <= 4 and _has_any(p_low, CONVERSATION_HINTS):
        return {
            "class": "conversation",
            "confidence": 0.85,
            "reasoning": "short conversational phrase",
            "phase": 1,
        }

    # Clarify FIRST — ambiguity signals trump everything else. Better to ask
    # one extra question than to dispatch the wrong subagent (karpathy P1).
    # Skip if it's clearly a single-target lookup ("show me X or Y" — really one task).
    has_clarify = bool(CLARIFY_RE.search(p_low))
    if has_clarify and word_count >= 4 and word_count <= 60:
        return {
            "class": "clarify",
            "confidence": 0.75,
            "reasoning": "ambiguity signal detected (or / vs / which / should i / etc)",
            "phase": 1,
        }

    # Research verbs win over build verbs when both appear — "research X for
    # build-to-sell SaaS" is a research task even though "build" is in there.
    # Research is a more specific intent statement; build words are often
    # incidental nouns or compound phrases ("build-to-sell", "build cost").
    has_research = _has_any(p_low, RESEARCH_VERBS)
    has_build = _has_any(p_low, BUILD_VERBS)

    # Long prompts almost always need main-thread context
    if word_count > 80 or line_count > 8 or has_code_fence:
        if has_research:
            klass = "multi-step-research"
        elif has_build:
            klass = "multi-step-build"
        else:
            klass = "multi-step-research"
        return {
            "class": klass,
            "confidence": 0.8,
            "reasoning": f"long/multi-line prompt (words={word_count}, lines={line_count}, code={has_code_fence})",
            "phase": 1,
        }

    # Research verbs FIRST — main thread (multi-step-research)
    if has_research:
        return {
            "class": "multi-step-research",
            "confidence": 0.75,
            "reasoning": "research/audit/review verb detected",
            "phase": 1,
        }

    # Build verbs — main thread (multi-step-build)
    if has_build:
        # Allow trivial one-liners ("send a TG saying hi") to slip through to one-shot
        if word_count <= 12 and ("send" in p_low or "ping" in p_low or "post" in p_low):
            return {
                "class": "one-shot",
                "confidence": 0.7,
                "reasoning": "short send/ping verb in <=12 words",
                "phase": 1,
            }
        return {
            "class": "multi-step-build",
            "confidence": 0.75,
            "reasoning": "build/ship/refactor verb detected",
            "phase": 1,
        }

    # Short factual question — one-shot
    if has_question_mark and word_count <= 25:
        return {
            "class": "one-shot",
            "confidence": 0.75,
            "reasoning": "short factual question",
            "phase": 1,
        }

    # Lookup/list/check verbs — one-shot
    if _has_any(p_low, ONE_SHOT_VERBS) and word_count <= 30:
        return {
            "class": "one-shot",
            "confidence": 0.7,
            "reasoning": "short lookup verb",
            "phase": 1,
        }

    # Default: route to main thread (safer — never silently drop work)
    return {
        "class": "conversation",
        "confidence": 0.4,
        "reasoning": "no strong signal; defaulting to main-thread conversation",
        "phase": 1,
    }


USAGE = """\
router — pre-prompt classifier (Phase 1 heuristic)

Usage:
  router.py classify <prompt_text>
  echo "<prompt>" | router.py classify -
"""


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help", "help"):
        print(USAGE, file=sys.stderr)
        return 0 if (len(argv) >= 2 and argv[1] in ("-h", "--help", "help")) else 2
    if argv[1] != "classify":
        print(USAGE, file=sys.stderr)
        return 2
    if len(argv) >= 3 and argv[2] == "-":
        prompt = sys.stdin.read()
    elif len(argv) >= 3:
        prompt = " ".join(argv[2:])
    else:
        print(USAGE, file=sys.stderr)
        return 2
    try:
        result = classify(prompt)
    except Exception as e:  # fail open
        result = {
            "class": "conversation",
            "confidence": 0.0,
            "reasoning": f"router crashed: {e!r}",
            "phase": 1,
        }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
