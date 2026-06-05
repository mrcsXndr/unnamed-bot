#!/usr/bin/env node
/**
 * Context Warning Hook
 *
 * Wire this as a `UserPromptSubmit` hook in `.claude/settings.json`. It fires
 * before each user prompt and warns Claude (via stderr → conversation system
 * message) when the session is approaching the context window limit.
 *
 * **Why this exists**: native auto-compact handles most cases, but a single
 * large tool result can spike usage in one turn. This gives early warnings and
 * (optionally) a Telegram alert as a safety net.
 *
 * **How it computes context %**: reads the most recent JSONL session log in
 * `~/.claude/projects/<encoded-cwd>/`, finds the latest `assistant` message,
 * and sums input + cache-creation + cache-read tokens. That / context_limit =
 * used. Limit defaults to 200K (1M for Opus if you run a 1M-context model).
 *
 * **Thresholds** (against the effective working ceiling — see AUTOCOMPACT_PCT):
 *   < 20% remaining → stderr WARN
 *   < 10% remaining → stderr URGENT (suggest /compact)
 *   <  5% remaining → stderr CRITICAL + optional Telegram alert
 *
 * **Config (env vars, all optional)**:
 *   CONTEXT_LIMIT_TOKENS          override the base window (e.g. 1000000)
 *   CLAUDE_AUTOCOMPACT_PCT_OVERRIDE  % of window where auto-compact fires
 *   TG_SEND_SCRIPT                path to tg_send.py for CRITICAL alerts
 *                                (if unset / missing, no Telegram is sent)
 *
 * **Safe by design**: never blocks the prompt (always exits 0), never modifies
 * session state, rate-limits Telegram to once / 10 min, silent if it can't find
 * the session log.
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

// Repo root = parent of this tools/ dir.
const REPO_DIR = path.resolve(__dirname, '..');
const PROJECTS_DIR = path.join(os.homedir(), '.claude', 'projects');
const TG_RATE_LIMIT_FILE = path.join(os.homedir(), '.claude', '.context_warn_tg_lock');
const TG_RATE_LIMIT_MS = 10 * 60 * 1000; // 10 minutes
const TG_SEND_SCRIPT = process.env.TG_SEND_SCRIPT || path.join(REPO_DIR, 'tools', 'tg_send.py');
const CONTEXT_STATE_FILE = path.join(REPO_DIR, '.context_state.json');

// Base context window. Override via CONTEXT_LIMIT_TOKENS for 1M-context models.
const ENV_LIMIT = parseInt(process.env.CONTEXT_LIMIT_TOKENS || '', 10);
const DEFAULT_LIMIT = Number.isFinite(ENV_LIMIT) && ENV_LIMIT > 0 ? ENV_LIMIT : 200_000;

// Auto-compact fires at CLAUDE_AUTOCOMPACT_PCT_OVERRIDE% of the window. That is
// the effective working ceiling, so report usage against it.
const AUTOCOMPACT_PCT = (() => {
  const v = parseInt(process.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE || '', 10);
  return Number.isFinite(v) && v > 0 && v < 100 ? v : 100;
})();

function baseLimitForModel(model) {
  if (process.env.CONTEXT_LIMIT_TOKENS) return DEFAULT_LIMIT;
  const m = (model || '').toLowerCase();
  // Standard windows; bump CONTEXT_LIMIT_TOKENS if you run a 1M-context model.
  if (m.includes('opus') || m.includes('sonnet') || m.includes('haiku')) return DEFAULT_LIMIT;
  return DEFAULT_LIMIT;
}

function limitForModel(model) {
  return Math.round(baseLimitForModel(model) * AUTOCOMPACT_PCT / 100);
}

function readStdinJson() {
  try {
    return JSON.parse(fs.readFileSync(0, 'utf-8'));
  } catch {
    return {};
  }
}

function encodeCwd(cwd) {
  // Claude Code's project-dir encoding: ':' → '-', '/' → '-', '\\' → '-'.
  return cwd.replace(/\\/g, '/').replace(/[:/]/g, '-');
}

function findLatestSessionJsonl(cwd) {
  if (!fs.existsSync(PROJECTS_DIR)) return null;

  const expected = encodeCwd(cwd);
  let projectDir = path.join(PROJECTS_DIR, expected);
  if (!fs.existsSync(projectDir)) {
    const lc = expected.replace(/^[A-Z]/, c => c.toLowerCase());
    const lcPath = path.join(PROJECTS_DIR, lc);
    if (fs.existsSync(lcPath)) projectDir = lcPath;
    else return null;
  }

  let newest = null;
  let newestMtime = 0;
  for (const file of fs.readdirSync(projectDir)) {
    if (!file.endsWith('.jsonl')) continue;
    const full = path.join(projectDir, file);
    const stat = fs.statSync(full);
    if (stat.mtimeMs > newestMtime) {
      newestMtime = stat.mtimeMs;
      newest = full;
    }
  }
  return newest;
}

function readLastUsage(jsonlPath) {
  // Read the last 256KB and scan backward for the latest assistant usage block.
  try {
    const stat = fs.statSync(jsonlPath);
    const start = Math.max(0, stat.size - 256 * 1024);
    const fd = fs.openSync(jsonlPath, 'r');
    const buf = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    const text = buf.toString('utf-8');
    const lines = text.split('\n').filter(l => l.trim());
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const entry = JSON.parse(lines[i]);
        if (entry.type === 'assistant' && entry.message?.usage) {
          return {
            usage: entry.message.usage,
            model: entry.message.model || 'unknown',
          };
        }
      } catch {}
    }
  } catch {}
  return null;
}

function computeContextPercent(usage, model) {
  const used =
    (usage.input_tokens || 0) +
    (usage.cache_creation_input_tokens || 0) +
    (usage.cache_read_input_tokens || 0);
  const limit = limitForModel(model);
  const remainingPct = Math.max(0, 100 - (used / limit) * 100);
  return { used, limit, remainingPct };
}

function rateLimitedTg(text) {
  // Skip entirely if no tg_send script is available.
  if (!fs.existsSync(TG_SEND_SCRIPT)) return false;
  try {
    if (fs.existsSync(TG_RATE_LIMIT_FILE)) {
      const last = parseInt(fs.readFileSync(TG_RATE_LIMIT_FILE, 'utf-8'), 10);
      if (Date.now() - last < TG_RATE_LIMIT_MS) return false;
    }
    fs.writeFileSync(TG_RATE_LIMIT_FILE, String(Date.now()));
    execFileSync('python', [TG_SEND_SCRIPT, text], {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10_000,
    });
    return true;
  } catch (e) {
    process.stderr.write(`[context_warn] tg send failed: ${e.message}\n`);
    return false;
  }
}

function main() {
  const input = readStdinJson();
  const cwd = (input.cwd || process.cwd()).replace(/\\/g, '/');

  const jsonl = findLatestSessionJsonl(cwd);
  if (!jsonl) process.exit(0); // No session log — stay silent.

  const last = readLastUsage(jsonl);
  if (!last) process.exit(0);

  const { used, limit, remainingPct } = computeContextPercent(last.usage, last.model);
  const remPct = remainingPct.toFixed(1);
  const usedK = (used / 1000).toFixed(0);
  const limitK = (limit / 1000).toFixed(0);
  const usedPct = 100 - remainingPct;

  // Write a context-state file for external monitors / status tooling.
  try {
    const state = {
      percent_used: Number(usedPct.toFixed(2)),
      percent_remaining: Number(remPct),
      used_tokens: used,
      limit_tokens: limit,
      model: last.model,
      last_updated: new Date().toISOString(),
      session_jsonl: jsonl,
    };
    fs.writeFileSync(CONTEXT_STATE_FILE, JSON.stringify(state, null, 2));
  } catch (e) {
    process.stderr.write(`[context_warn] state file write failed: ${e.message}\n`);
  }

  if (remainingPct < 5) {
    process.stderr.write(
      `[context_warn] CRITICAL: ${remPct}% context remaining ` +
      `(${usedK}k / ${limitK}k, model=${last.model}). RUN /compact NOW or the session may overflow.\n`
    );
    rateLimitedTg(`context CRITICAL: ${remPct}% remaining (${usedK}k/${limitK}k). consider /compact.`);
  } else if (remainingPct < 10) {
    process.stderr.write(
      `[context_warn] URGENT: ${remPct}% context remaining ` +
      `(${usedK}k / ${limitK}k, model=${last.model}). Should /compact soon.\n`
    );
  } else if (remainingPct < 20) {
    process.stderr.write(
      `[context_warn] WARN: ${remPct}% context remaining ` +
      `(${usedK}k / ${limitK}k, model=${last.model}).\n`
    );
  }
  // Above 20% — silent.

  process.exit(0);
}

main();
