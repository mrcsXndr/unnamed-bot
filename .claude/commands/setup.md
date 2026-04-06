Interactive setup wizard with compliance-aware questionnaire.

## Phase 1: Get to know the user

Ask these questions one at a time, wait for answers:

1. **"What's your name?"** → Save to CLAUDE.md as [USER]
2. **"What would you like to call your bot?"** → Save as [BotName]
3. **"What's your role? (e.g., CEO, CTO, Product Manager, Freelancer)"** → Determines what access levels are appropriate
4. **"What company/companies do you work with?"** → Add to CLAUDE.md domains
5. **"What's your primary email?"** → Used for calendar, email scanning
6. **"Do you manage other people's data? (employees, customers, etc.)"** → Compliance flag

## Phase 2: Compliance assessment

Based on role and data management answers, assess:

- **If they manage customer data**: Warn about GDPR/privacy implications of AI accessing emails/CRM with customer PII. Recommend: only scan subject lines, never forward customer data, don't store PII in context/memory.
- **If they manage employee data**: Warn about employment law — AI reading employee emails/Slack may require disclosure. Recommend: only scan channels they own/admin, not private DMs of employees.
- **If they're in a regulated industry** (finance, healthcare, legal): Extra caution — suggest they check with compliance/legal before enabling email and Slack scanning.
- **If they explicitly acknowledge and accept**: Proceed with full setup. Log their acceptance.

Ask: **"Based on your role, here are the data access implications. Do you want to proceed with full access, limited access, or skip certain integrations?"**

Options:
- **Full**: Calendar + Email + Tasks + Slack + Drive + Sheets (all read-write)
- **Limited**: Calendar + Tasks + Sheets only (no email/Slack scanning)
- **Custom**: Let them pick which integrations to enable

## Phase 3: Technical setup (based on chosen access level)

For each enabled integration, guide step-by-step:

### Google Workspace (Calendar, Gmail, Tasks, Drive, Sheets)
1. Go to https://console.cloud.google.com/
2. Create a project (or use existing)
3. Enable APIs: Calendar, Gmail, Tasks, Sheets, Drive
4. Create OAuth 2.0 credentials (Desktop app type)
5. Download `credentials.json` to this project root
6. Run: `python tools/google_workspace.py calendar-today` → triggers OAuth flow
7. Authorize in browser → `token.json` is created
8. Test: `bash tools/calendar.sh today`

### Slack
1. Go to https://api.slack.com/apps → Create New App → From scratch
2. Name it "[BotName]", select your workspace
3. OAuth & Permissions → User Token Scopes → Add:
   - channels:history, channels:read, groups:history, groups:read
   - im:history, im:read, mpim:history, mpim:read
   - users:read, search:read
4. Install to workspace → Copy User OAuth Token (xoxp-...)
5. Add to .env: `SLACK_USER_TOKEN=xoxp-...`
6. Test: `bash tools/slack.sh channels`

### GitLab (optional)
1. Go to https://gitlab.com/-/user_settings/personal_access_tokens
2. Create token with scopes: api, read_user, read_repository
3. Add to .env: `GITLAB_PERSONAL_ACCESS_TOKEN=glpat-...`

### Resend / Email sending (optional)
1. Go to https://resend.com → Create account → Get API key
2. Add domain verification
3. Add to .env: `RESEND_API_KEY=re_...`

### Google Drive sync (multi-machine)
1. Install Google Drive for Desktop
2. Create backup folder: `G:/My Drive/Backup/[botname]-secrets/`
3. Run: `bash tools/sync_settings.sh push`

## Phase 4: Task Board setup

1. Create a new Google Sheet
2. Name it: "[BotName] — Task Board"
3. Add headers in row 1: Done | Priority | Source | Who | Task | Due | Notes | Added
4. Copy the Sheet ID from the URL
5. Update CLAUDE.md with the Sheet ID
6. Test: `bash tools/sheets.sh read "SHEET_ID" "Tasks!A:H"`

## Phase 5: Verify everything

Run each enabled integration and report status:
- [ ] Calendar: `bash tools/calendar.sh today`
- [ ] Gmail: `bash tools/gmail.sh unread`
- [ ] Tasks: `bash tools/gtasks.sh list`
- [ ] Slack: `bash tools/slack.sh channels`
- [ ] Sheets: read task board
- [ ] Drive: `bash tools/drive.sh recent`

Report: what works, what's missing, next steps.

## Phase 6: Save configuration

- Update CLAUDE.md with user's details
- Save compliance choice to `context/compliance.md`
- Create `context/me.md` with user profile
- Run `bash tools/sync_settings.sh push` to backup
- Commit: "feat: initial setup complete for [USER]"
