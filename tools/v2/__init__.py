"""Bot v2 architecture modules.

Three-channel context management (Slack-pattern) + auto-hook router.

Modules
-------
journal  : director's journal — live structured working memory per session
timeline : critic's timeline — distilled chronological narrative
router   : pre-prompt classifier for one-shot vs multi-step (heuristic)
recall   : FTS5 cross-session recall over journals + timelines
safe_write : atomic, locked, drift-guarded writes to shared memory files
"""

__version__ = "0.1.0-scaffold"
