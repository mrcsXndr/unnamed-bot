#!/usr/bin/env node
/**
 * Memory Sync Hook
 *
 * Auto-syncs the bot's `memory/` directory across machines via this repo's git
 * remote, so your bot's accumulated knowledge follows you between computers.
 *
 * - **UserPromptSubmit / SessionStart**: pull-rebase from origin if remote is
 *   ahead. Catches up local memory before your next turn.
 * - **Stop / SubagentStop**: if `memory/` has uncommitted changes, commit +
 *   pull --rebase + push. Always pulls before pushing — never force-pushes,
 *   never overwrites remote. Retries push once if rejected.
 *   On rebase conflict: aborts (working tree stays clean), writes
 *   `MEMORY_SYNC_CONFLICT.md` at the repo root as a flag, exits cleanly so the
 *   bot can resolve it next session.
 *
 * **Repo-aware**: the hook auto-detects its own repo (the parent of tools/).
 * It only acts when the current Claude Code cwd is inside that same repo, so it
 * never touches your other projects.
 *
 * **Config (env vars, optional)**:
 *   MEMORY_GIT_REMOTE   default "origin"
 *   MEMORY_GIT_BRANCH   default "main"
 *   MEMORY_GIT_NAME     committer name  (default "bot-memory")
 *   MEMORY_GIT_EMAIL    committer email (default "bot-memory@localhost")
 *
 * **Safe by design**: never force-pushes; always pulls --rebase before push;
 * conflicts leave the tree clean and produce a flag file; single retry on
 * rejection; all output to stderr; always exits 0.
 *
 * NOTE: `memory/` must be committed to git (i.e. NOT in .gitignore) for this to
 * sync. Keep secrets OUT of memory/ — it is pushed to your remote.
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const REPO_DIR = path.resolve(__dirname, '..');
const MEMORY_DIR_NAME = 'memory';
const CONFLICT_FLAG = path.join(REPO_DIR, 'MEMORY_SYNC_CONFLICT.md');
const REMOTE = process.env.MEMORY_GIT_REMOTE || 'origin';
const BRANCH = process.env.MEMORY_GIT_BRANCH || 'main';
const GIT_NAME = process.env.MEMORY_GIT_NAME || 'bot-memory';
const GIT_EMAIL = process.env.MEMORY_GIT_EMAIL || 'bot-memory@localhost';

function readInput() {
  try {
    return JSON.parse(fs.readFileSync(0, 'utf-8'));
  } catch {
    return {};
  }
}

function isInThisRepo(input) {
  const cwd = (input.cwd || process.cwd()).replace(/\\/g, '/');
  return cwd.toLowerCase().startsWith(REPO_DIR.replace(/\\/g, '/').toLowerCase());
}

function git(cmd, opts = {}) {
  return execSync(`git ${cmd}`, {
    cwd: REPO_DIR,
    encoding: 'utf-8',
    stdio: ['ignore', 'pipe', 'pipe'],
    ...opts,
  });
}

function gitTry(cmd) {
  try {
    return { ok: true, output: git(cmd) };
  } catch (e) {
    const stderr = e.stderr ? e.stderr.toString() : '';
    return { ok: false, error: e.message, stderr };
  }
}

function gitSilent(cmd) {
  try {
    return git(cmd);
  } catch {
    return null;
  }
}

function log(msg) {
  process.stderr.write(`[memory-sync] ${msg}\n`);
}

function hasMemoryChanges() {
  const status = gitSilent(`status --porcelain ${MEMORY_DIR_NAME}/`);
  return status && status.trim().length > 0;
}

function writeConflictFlag(reason) {
  const ts = new Date().toISOString();
  const content = `# Memory Sync Conflict

A \`git pull --rebase\` failed at ${ts}.

**Reason**: ${reason}

## Resolve manually

\`\`\`bash
cd ${REPO_DIR}
git fetch ${REMOTE}
git pull --rebase
# Resolve any conflicts in memory/ files
git add memory/
git rebase --continue
git push ${REMOTE} ${BRANCH}
rm MEMORY_SYNC_CONFLICT.md
\`\`\`

## Or ask the bot to resolve

In your next Claude Code session, say:
"there's a memory sync conflict, please resolve it"

The bot will read both versions of the conflicting files and merge them.
`;
  fs.writeFileSync(CONFLICT_FLAG, content);
}

function safePullRebase() {
  if (fs.existsSync(CONFLICT_FLAG)) {
    return { ok: false, action: 'conflict-pending' };
  }

  const fetchResult = gitTry(`fetch ${REMOTE} ${BRANCH}`);
  if (!fetchResult.ok) {
    return { ok: true, action: 'fetch-failed-skip' };
  }

  const local = gitSilent('rev-parse HEAD')?.trim();
  const remote = gitSilent(`rev-parse ${REMOTE}/${BRANCH}`)?.trim();
  if (!local || !remote) {
    return { ok: true, action: 'no-refs-skip' };
  }
  if (local === remote) {
    return { ok: true, action: 'in-sync' };
  }

  try {
    git(`pull --rebase --autostash ${REMOTE} ${BRANCH}`);
    return { ok: true, action: 'rebased' };
  } catch (e) {
    gitSilent('rebase --abort');
    gitSilent('stash pop');
    writeConflictFlag(`pull --rebase failed: ${(e.stderr || e.message || '').toString().slice(0, 500)}`);
    return { ok: false, action: 'conflict', error: e.message };
  }
}

function commitAndPush(message) {
  if (!hasMemoryChanges()) {
    return { ok: true, action: 'no-changes' };
  }

  const addResult = gitTry(`add ${MEMORY_DIR_NAME}/`);
  if (!addResult.ok) {
    return { ok: false, action: 'stage-failed', error: addResult.error };
  }

  const cached = gitSilent('diff --cached --name-only');
  if (!cached || !cached.trim()) {
    return { ok: true, action: 'no-staged-changes' };
  }

  try {
    git(
      `-c user.email="${GIT_EMAIL}" -c user.name="${GIT_NAME}" commit -m "${message.replace(/"/g, '\\"')}"`
    );
  } catch (e) {
    return { ok: false, action: 'commit-failed', error: e.message };
  }

  const pullResult = safePullRebase();
  if (!pullResult.ok) {
    return pullResult;
  }

  try {
    git(`push ${REMOTE} ${BRANCH}`);
    return { ok: true, action: 'pushed' };
  } catch (e) {
    const pull2 = safePullRebase();
    if (!pull2.ok) return pull2;
    try {
      git(`push ${REMOTE} ${BRANCH}`);
      return { ok: true, action: 'pushed-retry' };
    } catch (e2) {
      return { ok: false, action: 'push-failed', error: e2.message };
    }
  }
}

// === Main ===

const input = readInput();

if (!isInThisRepo(input)) {
  process.exit(0); // Different project — do nothing.
}

if (!fs.existsSync(REPO_DIR)) {
  log(`repo dir missing: ${REPO_DIR} — skipping`);
  process.exit(0);
}

const event = input.hook_event_name || '';

try {
  if (event === 'UserPromptSubmit' || event === 'SessionStart') {
    const result = safePullRebase();
    log(`pull: ${result.action}${result.error ? ' — ' + result.error.slice(0, 200) : ''}`);
  } else if (event === 'Stop' || event === 'SubagentStop') {
    const sessionShort = (input.session_id || '').slice(0, 8) || 'unknown';
    const result = commitAndPush(`auto: memory sync from session ${sessionShort}`);
    log(`push: ${result.action}${result.error ? ' — ' + result.error.slice(0, 200) : ''}`);
  }
} catch (e) {
  log(`unexpected error: ${e.message}`);
}

process.exit(0);
