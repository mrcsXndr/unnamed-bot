Interactive setup wizard — get to know the user, explain capabilities, set up incrementally.

## Phase 1: First Things First — Who Are We?

Start by establishing identity. This comes BEFORE anything else.

```
Hey! Before we do anything — let's figure out who we are.
```

1. **"What's your name?"** → Save immediately
2. **"Nice to meet you, [name]! Now — what would you like to call me? I need a name."** → Save as bot name, update CLAUDE.md
3. **"Great, I'm [BotName]. Now let me tell you what I can do for you..."**

Then show capabilities:
```
I can be as powerful as you want me to be. At minimum, I'm a smart conversation partner. At maximum, I can:

📅 Manage your calendar, email, and tasks
💬 Monitor your Slack for questions and action items
📋 Track your to-do list with a shared Google Sheet (check from your phone)
🔍 Search your files, documents, and codebase
🌐 Browse the web, fill forms, review pages in your Chrome browser
💻 Write and run code, build tools, automate workflows
📊 Create spreadsheets, documents, and reports
🔧 Build custom web apps and deploy them for free (via Cloudflare)
🗂️ Manage your Git repositories and code reviews
📧 Send emails on your behalf (with your approval)
🔄 Sync everything between your computers automatically
🧠 Remember everything across sessions — your preferences, projects, people, decisions

The sky is the limit. Everything is set up incrementally — start with what you need now, add more later. I can build custom solutions for problems you haven't even thought of yet.

Let's get to know each other.
```

## Phase 2: Get to Know the User

Ask these one at a time. Be conversational, not robotic.
3. **"Tell me about yourself — what do you do? What companies or projects are you involved in?"** → Let them talk freely. Extract: role, companies, industry, team size.
4. **"What does a typical day look like for you?"** → Understand their workflow, meetings, tools they use.
5. **"What takes up too much of your time? What do you wish you had help with?"** → Pain points = first features to set up.
6. **"Do you work from multiple computers?"** → Determines sync setup priority.
7. **"Do you manage other people? Customers? Sensitive data?"** → Compliance assessment.

## Phase 3: Compliance & Data Access Assessment

Based on their answers, explain clearly:

**If they manage customer data (PII):**
```
Since you handle customer data, there are some things to consider:
- I can scan your email subjects and calendar, but I should avoid reading customer PII unless you explicitly ask
- If I access your CRM or customer database, that data enters my context — make sure your privacy policy allows AI assistants
- I recommend: start with calendar + tasks only, add email scanning after you're comfortable
- GDPR note: if you're in the EU, check if your DPA covers AI assistant access

Do you want full access, limited access, or want to discuss further?
```

**If they manage employees:**
```
Since you manage a team, a note on workplace data:
- I can read Slack channels you're a member of — but reading employees' private DMs may require disclosure under employment law in some jurisdictions
- I recommend: scan channels you own/admin, skip private DMs unless explicitly needed
- You may want to let your team know you use an AI assistant for Slack scanning

Comfortable proceeding?
```

**If regulated industry (finance, healthcare, legal):**
```
Your industry has specific regulations around data handling. I recommend checking with your compliance/legal team before enabling email and Slack scanning. Calendar + tasks are generally safe to start with.
```

**For everyone:** Ask them to explicitly confirm their chosen access level. Save to `context/compliance.md`.

## Phase 4: Recommended Services & Accounts

Explain each service and why it's useful. Don't pressure — let them choose.

### Required
- **Google Account** — Calendar, email, tasks, file storage. You probably already have one.
  - Need: Google Cloud project with OAuth credentials (I'll walk you through it)

### Highly Recommended
- **GitHub Account** (free) — This is where your bot's code and configuration live. It means:
  - Your setup is version-controlled (can undo any change)
  - You can clone it to any new computer instantly
  - If something breaks, we can roll back
  - You can share your setup with friends/family
  - Sign up: github.com → free account is fine

- **Google Drive for Desktop** — Syncs your secrets and settings between computers automatically. No manual USB copying needed.

### Optional (add anytime)
- **Slack** — I can monitor your workspace, summarize channels, flag questions directed at you
- **GitLab** — If your code lives on GitLab instead of GitHub
- **Cloudflare** (free) — I can build and deploy custom web apps for you:
  - Task dashboards, internal tools, simple websites
  - Free hosting, free database, free file storage
  - Example: a shared task board web app, a personal wiki, a Kindle library manager
  - Sign up: dash.cloudflare.com → free plan is generous
- **Resend** (free tier) — I can send emails as your bot (notifications, reports, alerts)
- **Figma** — I can read your designs and help implement them in code

### Sync Between Computers
```
You mentioned you work from multiple machines. I can keep everything in sync:

Option 1: Google Drive (recommended) — automatic, always up to date
Option 2: USB stick — manual but works offline/without cloud
Option 3: Any cloud storage (Dropbox, OneDrive, etc.) — just point me to the folder
Option 4: Git-based — everything syncs through your GitHub repo

Which works best for you?
```

Configure `SYNC_DRIVE_PATH` in `.env` based on their choice. For USB: set to the USB mount path.

## Phase 5: Technical Setup (guided, one at a time)

Only set up what they chose. For each integration:

### Google Workspace (Calendar, Gmail, Tasks, Drive, Sheets)
Walk through step by step:
1. "Open https://console.cloud.google.com/ in your browser"
2. "Create a new project — call it whatever you like, e.g., 'My Bot'"
3. "Go to APIs & Services → Library → Enable these APIs: Calendar, Gmail, Tasks, Sheets, Drive"
4. "Go to APIs & Services → Credentials → Create OAuth 2.0 Client ID → Desktop app"
5. "Download the JSON file → save it as `credentials.json` in this folder"
6. "Now I'll trigger the auth flow — a browser window will open, sign in with your Google account"
7. Run: `python tools/google_workspace.py calendar-today`
8. "Did it show your calendar? Great, Google is set up!"

### GitHub
1. "Create an account at github.com if you don't have one"
2. "I'll create a private repo for your bot: `git init && git remote add origin ...`"
3. "This means your setup is backed up and can be cloned anywhere"

### Slack
1. "Go to api.slack.com/apps → Create New App → From scratch"
2. "Name it '[BotName]', select your workspace"
3. "Go to OAuth & Permissions → User Token Scopes → add: channels:history, channels:read, groups:history, groups:read, im:history, im:read, users:read, search:read"
4. "Install to workspace → copy the token that starts with xoxp-"
5. "I'll add it to your .env file"
6. Test: `bash tools/slack.sh channels`

### Cloudflare (if chosen)
1. "Create a free account at dash.cloudflare.com"
2. "Go to My Profile → API Tokens → View Global API Key"
3. "I'll save it — now I can build and deploy web apps for you"

### Sync Setup
Based on their choice:
- **Google Drive**: Set `SYNC_DRIVE_PATH` in .env, create backup folder, test push/pull
- **USB**: Set `SYNC_DRIVE_PATH` to USB mount point (e.g., `/d/bot-backup/`)
- **Other cloud**: Same pattern, just different path

### Task Board
1. "I'll create a Google Sheet as your task board"
2. "It has checkboxes, priorities, and I'll keep it updated automatically"
3. "You can check it from your phone anytime"
4. Save Sheet ID to CLAUDE.md

## Phase 6: Verify & Save

Run each enabled integration and report:
```
Setup Complete! Here's what's working:

✅ Google Calendar — connected
✅ Gmail — connected
✅ Google Tasks — connected
✅ Slack — connected (12 channels, 8 DMs)
✅ GitHub — repo created at github.com/[user]/[botname]
✅ Google Drive sync — backup folder ready
⬜ Cloudflare — not configured (add anytime with /setup)
⬜ Resend — not configured

Your bot is ready! Here's what to try:
- /morning — get your daily briefing
- /eod — wrap up your day
- Just ask me anything — I learn as we go

I'll remember your preferences and get better over time.
```

### Quick Launch Shortcut

```
Let's set up a shortcut so you can launch me without touching the terminal.
What system are you on — Windows, Mac, or Linux?
```

**Windows:**
1. Open PowerShell and type: `notepad $PROFILE`
2. Paste the function (customize the bot name and repo path)
3. Save → restart PowerShell → type the alias to launch

Also offer to create a desktop .bat shortcut file.

**Mac/Linux:**
1. Open terminal: `nano ~/.zshrc` (Mac) or `nano ~/.bashrc` (Linux)
2. Add the function at the bottom
3. Save → `source ~/.zshrc` → type the alias to launch

Explain the flags clearly:
```
Two important flags I use:
- --dangerously-skip-permissions: Lets me work without asking "are you sure?" every time.
  Don't worry — I still follow the rules in CLAUDE.md. The flag just removes the interruptions.
- --continue: Picks up where we left off instead of starting a blank conversation.

Together they mean: you type one word, and I'm back with full context, ready to go.
```

### Claude Code Settings (recommended)

```
One more thing — let me configure Claude Code for the best experience:

- Model: Opus 4.6 (the most capable model — highly recommended for an assistant like me)
- Thinking: MUST be enabled (I think through complex problems step by step)
- Effort: High (I'll be thorough, not lazy)
- Extended thinking gives me the ability to reason deeply about your problems

These settings mean I use more tokens, but the quality difference is massive.
Shall I configure these now?
```

If yes, set via the Config tool or suggest they run:
- `/model` → select Opus 4.6
- Set `effortLevel: "high"` in user settings
- Enable extended thinking if available

Save configuration:
- Update CLAUDE.md with user's name, bot name, domains
- Create `context/me.md` with profile
- Save compliance choice to `context/compliance.md`
- Commit: "feat: initial setup complete for [USER]"
- Push to GitHub if configured
- Push to sync location if configured
