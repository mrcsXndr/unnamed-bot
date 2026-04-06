Run the daily morning briefing.

## Steps:

1. **Calendar** — Run `bash tools/calendar.sh today` to get today's events
2. **Priority Emails** — Run `bash tools/gmail.sh priority` to check unread priority emails
3. **All Unread** — Run `bash tools/gmail.sh unread` for full unread list
4. **Google Tasks** — Run `bash tools/gtasks.sh list` to show open tasks
5. **Slack** — Run `bash tools/slack.sh unread` for unread channels
6. **Task Board** — Read the task board sheet for open items

## Output Format — Ultra-concise, bulleted:
```
## [Date] Morning Briefing

### Calendar
- [time] [meeting]

### Priority Emails ([count] unread)
- [from] — [subject]

### Open Tasks ([count])
- [task] — due [date]

### Slack
- [channel]: [unread count]
```
