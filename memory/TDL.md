# TDL — persistent backlog

Single, hand-maintained list of everything undone / blocked / deferred, so
nothing lives only in session context. Edit this file directly (Write/Edit).
The session-start hook injects the `## Open` section below into every new
session. Keep items rich: status tag + exact next step + blocker.

- Add or update a `###` item under `## Open` whenever a turn ends with work
  unfinished. Update items in place as they progress; don't just append.
- Drop a one-line Journal entry naming `memory/TDL.md` so the pointer survives
  compaction.
- On ship (tested + deployed + verified), move the item to `## Done` with a
  one-line outcome + date. Trim `## Done` to ~15 rows.

## Open

_(Nothing open yet. Example of the shape an item should take:)_

<!--
### Example task title
- **Status:** in progress / blocked / deferred / awaiting owner
- **Next step:** the exact next action
- **Blocker:** who/what is blocking, if anything
- **Links:** relevant files, PRs, URLs
-->

## Done

_(Shipped items land here with a one-line outcome + date.)_
