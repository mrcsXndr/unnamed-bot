// the bot statusline — model, git, context %, lifetime API cost
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

// API pricing per million tokens (USD)
const PRICING = {
  opus:   { input: 15, cache_write: 3.75, cache_read: 1.50, output: 75 },
  sonnet: { input: 3,  cache_write: 0.75, cache_read: 0.30, output: 15 },
  haiku:  { input: 0.8, cache_write: 0.2,  cache_read: 0.08, output: 4 },
};
const USD_TO_EUR = 0.92;
// Honor CLAUDE_CONFIG_DIR so per-personality bot instances read their own
// config home (transcripts, cost cache, bot.pid) instead of the real ~/.claude.
const CONFIG_HOME = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const COST_CACHE = path.join(CONFIG_HOME, 'api_cost_cache.json');
const CACHE_TTL_MS = 86_400_000; // recalculate once per day (session start triggers it)

function getTier(model) {
  const m = (model || '').toLowerCase();
  if (m.includes('sonnet')) return 'sonnet';
  if (m.includes('haiku')) return 'haiku';
  return 'opus';
}

function calcLifetimeCost() {
  let total = 0;
  const projectsDir = path.join(CONFIG_HOME, 'projects');
  try {
    for (const proj of fs.readdirSync(projectsDir)) {
      const projPath = path.join(projectsDir, proj);
      if (!fs.statSync(projPath).isDirectory()) continue;
      for (const file of fs.readdirSync(projPath)) {
        if (!file.endsWith('.jsonl')) continue;
        const lines = fs.readFileSync(path.join(projPath, file), 'utf8').split('\n');
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const entry = JSON.parse(line);
            if (entry.type !== 'assistant' || !entry.message) continue;
            const u = entry.message.usage || {};
            const p = PRICING[getTier(entry.message.model)];
            total += (
              (u.input_tokens || 0) * p.input +
              (u.cache_creation_input_tokens || 0) * p.cache_write +
              (u.cache_read_input_tokens || 0) * p.cache_read +
              (u.output_tokens || 0) * p.output
            ) / 1e6;
          } catch (e) {}
        }
      }
    }
  } catch (e) {}
  return total * USD_TO_EUR;
}

function getCachedCost() {
  try {
    const cached = JSON.parse(fs.readFileSync(COST_CACHE, 'utf8'));
    if (Date.now() - cached.ts < CACHE_TTL_MS) return cached.eur;
  } catch (e) {}
  // Recalculate
  const eur = calcLifetimeCost();
  try { fs.writeFileSync(COST_CACHE, JSON.stringify({ eur, ts: Date.now() })); } catch (e) {}
  return eur;
}

// TG channel health: green if the plugin's bot.pid process is alive, red otherwise.
// Only shown for the instance that OWNS the TG poller: the launcher exports
// BOT_HAS_TG='1' when it acquired --channels, '0' when a foreign owner held
// the slot (so this instance launched without --channels). '0' => hide the TG
// indicator entirely (this instance doesn't have TG). Unset => legacy/unknown,
// keep showing it (don't regress sessions launched before this gate).
function tgStatus() {
  if (process.env.BOT_HAS_TG === '0') return '';
  try {
    const pidFile = path.join(CONFIG_HOME, 'channels', 'telegram', 'bot.pid');
    const pid = parseInt(fs.readFileSync(pidFile, 'utf8').trim(), 10);
    if (!pid) return 'TG\u{1F534}';
    process.kill(pid, 0); // throws ESRCH if dead, EPERM if alive-but-not-ours (still alive)
    return 'TG\u{1F7E2}';
  } catch (e) {
    if (e && e.code === 'EPERM') return 'TG\u{1F7E2}';
    return 'TG\u{1F534}';
  }
}

let d = '';
process.stdin.on('data', c => d += c);
process.stdin.on('end', () => {
  try {
    const j = JSON.parse(d);
    const m = (j.model?.display_name || '?').replace(/^Claude /, '');
    const dir = j.workspace?.current_dir || '';

    let g = '';
    try {
      const b = execSync('git symbolic-ref --short HEAD', { cwd: dir, stdio: ['pipe', 'pipe', 'pipe'] }).toString().trim();
      const s = execSync('git --no-optional-locks status --porcelain', { cwd: dir, stdio: ['pipe', 'pipe', 'pipe'] }).toString();
      g = s.trim() ? `(${b}*)` : `(${b})`;
    } catch (e) {}

    const pct = Math.round(j.context_window?.remaining_percentage || 0);
    const BAR = 10;
    const filled = Math.round(pct / 100 * BAR);
    const bar = '[' + '\u2588'.repeat(filled) + '\u2591'.repeat(BAR - filled) + '] ' + pct + '%';

    const costEur = getCachedCost();
    const costStr = costEur >= 1000 ? `\u20ac${(costEur/1000).toFixed(1)}k` : `\u20ac${costEur.toFixed(0)}`;

    console.log([m, dir + (g ? ' ' + g : ''), bar, costStr, tgStatus()].filter(Boolean).join(' | '));
  } catch (e) {
    console.log('...');
  }
});
