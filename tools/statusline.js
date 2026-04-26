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
const COST_CACHE = path.join(os.homedir(), '.claude', 'api_cost_cache.json');
const CACHE_TTL_MS = 86_400_000; // recalculate once per day (session start triggers it)

function getTier(model) {
  const m = (model || '').toLowerCase();
  if (m.includes('sonnet')) return 'sonnet';
  if (m.includes('haiku')) return 'haiku';
  return 'opus';
}

function calcLifetimeCost() {
  let total = 0;
  const projectsDir = path.join(os.homedir(), '.claude', 'projects');
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

    console.log([m, dir + (g ? ' ' + g : ''), bar, costStr].join(' | '));
  } catch (e) {
    console.log('...');
  }
});
