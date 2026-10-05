#!/usr/bin/env node

// SST3 statusline (#406 Phase 2 rewrite):
// - F2.6: CI status cached to ~/.cache/sst3/ci-<hash>.json with TTL, background refresh
// - F2.7: transcript read ONCE per render, parsed ONCE, reused for findTouchedRepos + token usage
// - F2.8: per-repo git info batched into ONE git call instead of 4-5
// - F2.9: silent catches replaced with rate-limited debug log
// - F2.10: gh availability probed once per process, cached in module scope
//
// Anti-RTK rule: no network calls in render path. CI cache is read-only at render time,
// background process refreshes asynchronously.

const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execSync, spawn } = require('child_process');

// ── Constants (would live in sst3_limits.py for Python; here inline) ──
const CACHE_DIR = path.join(os.homedir(), '.cache', 'sst3');
const CI_CACHE_TTL_MS = 60_000;            // 1 minute — render-path read only
const ERROR_LOG = path.join(CACHE_DIR, 'statusline-errors.jsonl');
const ERROR_RATE_LIMIT_MS = 60_000;        // one entry per category per minute
const GH_PROBE_CACHE_KEY = '__gh_available__';

// The context-occupancy formula (BASELINE_OVERHEAD / LAG_BUFFER_PERCENT / window
// selection) lives in ONE place since #568 Phase 3, because the UserPromptSubmit hook
// injects the same reading into the agent's context and a second copy would drift
// (AP #10). This file renders it; the module computes it.
//
// GUARDED because a bare module-scope require is the one failure this file cannot
// absorb: an absent sibling throws before renderStatusline() exists and the operator's
// statusline goes BLANK, not degraded. That is reachable during a checkout or bisect
// while a session is live. Everything else here routes through logErr by design
// (see F2.9 in the header); the require must too. One missing segment, never a dead bar.
//
// DECLARED HERE, LOADED BELOW. The load sits after `_errorLogTimes` on purpose: logErr
// reads that const, so a catch placed above it could not call logErr at all — it would
// hit the temporal dead zone. The first version of this guard was written above and its
// comment claimed it logged; it silently could not, which is the same
// vanishes-with-nothing-logged failure this Issue exists to end.
let contextGauge = null;

// ── Module-scope process caches (live for one render only — fresh process each time) ──
let _ghAvailable = null; // F2.10
const _errorLogTimes = new Map(); // F2.9 rate limit

try {
  contextGauge = require('./hooks/_lib-context-gauge.js');
} catch (e) {
  contextGauge = null;
  logErr('context-gauge-module-missing', e);
}

function ensureCacheDir() {
  try {
    fs.mkdirSync(CACHE_DIR, { recursive: true });
  } catch (e) {
    // Best-effort; logged via logErr
    logErr('cache-dir-mkdir', e);
  }
}

function logErr(category, err) {
  const now = Date.now();
  const last = _errorLogTimes.get(category) || 0;
  if (now - last < ERROR_RATE_LIMIT_MS) return;
  _errorLogTimes.set(category, now);
  try {
    ensureCacheDir();
    const entry = JSON.stringify({
      ts: new Date().toISOString(),
      category,
      error: String(err && err.message ? err.message : err),
    }) + '\n';
    fs.appendFileSync(ERROR_LOG, entry);
  } catch (_) {
    // Cannot log: writing to stderr would corrupt the statusline.
    // Last-resort: drop silently. AP #12 cap already enforced via the
    // best-effort path above.
  }
}

function ghAvailable() {
  if (_ghAvailable !== null) return _ghAvailable;
  try {
    execSync('gh --version', { stdio: 'ignore' });
    _ghAvailable = true;
  } catch (e) {
    logErr('gh-probe', e);
    _ghAvailable = false;
  }
  return _ghAvailable;
}

// Read JSON from stdin
// 1M-context model detection (#509 AC5.1). Marker-first so a future model tagged
// with a `[1m]` / "1M" marker is caught WITHOUT a code change; the family allowlist
// covers ids that omit the marker (Claude Code may present either id form, e.g.
// `claude-opus-4-8` or `claude-opus-4-8[1m]`). Exported for unit testing.
// Re-exported below for claude/statusline.test.js, which has imported it from here since
// before #568 moved the definition into the shared gauge module. Falls back to a stub so
// a missing module degrades one segment rather than throwing at load.
const is1MContext = contextGauge ? contextGauge.is1MContext : (() => false);

let input = '';
function renderStatusline() {
  try {
    const data = JSON.parse(input);

    // ANSI color codes
    const colors = {
      reset: '\x1b[0m',
      cyan: '\x1b[36m',
      green: '\x1b[32m',
      yellow: '\x1b[33m',
      blue: '\x1b[34m',
      magenta: '\x1b[35m',
      gray: '\x1b[90m',
      red: '\x1b[31m',
      bold: '\x1b[1m',
    };

    const ccSegments = [];
    const allGhLines = [];

    // ── F2.7: read + parse transcript ONCE ──
    // Parsed by the shared gauge module since #568 Phase 3 — the loop lived here and in
    // the module, differing only in whether a bad line was logged, which is a callback,
    // not a reason for two copies (AP #10). logErr keeps this file's own error contract.
    const transcriptPath = data.transcript_path;
    let transcriptEntries = [];
    if (transcriptPath && fs.existsSync(transcriptPath)) {
      transcriptEntries = contextGauge
        ? contextGauge.parseTranscript(transcriptPath, logErr)
        : [];
    }

    // ── findTouchedRepos: uses pre-parsed entries ──
    function findTouchedRepos() {
      const repos = new Set();
      const currentDir = data.workspace?.current_dir || data.cwd;
      if (currentDir && fs.existsSync(currentDir)) {
        try {
          execSync('git rev-parse --git-dir', { cwd: currentDir, stdio: 'ignore' });
          repos.add(currentDir);
        } catch (e) {
          logErr('git-probe-cwd', e);
        }
      }

      for (const entry of transcriptEntries) {
        if (entry.type !== 'assistant' || !entry.message?.content) continue;
        for (const content of entry.message.content) {
          if (content.type !== 'tool_use' || content.name !== 'Bash' || !content.input) continue;
          const command = content.input.command;
          if (!command || !command.includes('git ')) continue;
          const cdMatch = command.match(/cd\s+"([^"]+)"/);
          if (!cdMatch) continue;
          const repoPath = cdMatch[1];
          if (!fs.existsSync(repoPath)) continue;
          try {
            execSync('git rev-parse --git-dir', { cwd: repoPath, stdio: 'ignore' });
            repos.add(repoPath);
          } catch (e) {
            logErr('git-probe-transcript', e);
          }
        }
      }
      return Array.from(repos);
    }

    ccSegments.push(`${colors.yellow}${colors.bold}CC:${colors.reset}`);

    // ── F2.6: CI status from cache (no render-path network call) ──
    function readCachedCI(repoPath) {
      const hash = crypto.createHash('sha1').update(repoPath).digest('hex').slice(0, 12);
      const cacheFile = path.join(CACHE_DIR, `ci-${hash}.json`);
      try {
        const stat = fs.statSync(cacheFile);
        if (Date.now() - stat.mtimeMs < CI_CACHE_TTL_MS) {
          return JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
        }
      } catch (e) {
        if (e.code !== 'ENOENT') logErr('ci-cache-read', e);
      }
      // Stale or missing — kick off background refresh, return null
      ensureCacheDir();
      try {
        const tmp = `${cacheFile}.tmp`;
        const child = spawn('sh', ['-c',
          `gh run list --limit 1 --json status,conclusion > "${tmp}" 2>/dev/null && mv "${tmp}" "${cacheFile}"`,
        ], { cwd: repoPath, detached: true, stdio: 'ignore' });
        child.unref();
      } catch (e) {
        logErr('ci-cache-refresh-spawn', e);
      }
      return null;
    }

    // ── F2.8: batched git info per repo (single shell-out) ──
    // Uses a NUL-delimited multi-command pipeline so we get branch, sync,
    // dirty, and last-commit in ONE child process per repo instead of 5.
    function batchedGitInfo(repoPath) {
      try {
        const out = execSync(
          'git rev-parse --abbrev-ref HEAD; printf "\\0"; ' +
          'git status -sb --porcelain; printf "\\0"; ' +
          'git status --porcelain; printf "\\0"; ' +
          'git log -1 --format=%ar',
          { cwd: repoPath, encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }
        );
        const parts = out.split('\0');
        return {
          branch: (parts[0] || '').trim(),
          sb: (parts[1] || '').trim(),
          status: (parts[2] || '').trim(),
          commitTime: (parts[3] || '').trim(),
        };
      } catch (e) {
        logErr('git-batched', e);
        return null;
      }
    }

    function generateGhLine(repoPath) {
      const ghSegments = [];
      ghSegments.push(`${colors.blue}${colors.bold}GH:${colors.reset}`);
      const repoName = path.basename(repoPath);
      const info = batchedGitInfo(repoPath);
      if (!info || !info.branch) return null;

      let branchInfo = `${repoName} (⎇ ${info.branch}`;

      const firstSb = info.sb.split('\n')[0] || '';
      const aheadMatch = firstSb.match(/ahead (\d+)/);
      const behindMatch = firstSb.match(/behind (\d+)/);
      if (aheadMatch) branchInfo += ` ${colors.green}↑${aheadMatch[1]}${colors.reset}`;
      if (behindMatch) branchInfo += ` ${colors.yellow}↓${behindMatch[1]}${colors.reset}`;

      if (info.status.length > 0) {
        branchInfo += ` ${colors.red}⚡${colors.reset}`;
      }

      if (info.commitTime) {
        const shortTime = info.commitTime
          .replace(' seconds', 's').replace(' second', 's')
          .replace(' minutes', 'm').replace(' minute', 'm')
          .replace(' hours', 'h').replace(' hour', 'h')
          .replace(' days', 'd').replace(' day', 'd')
          .replace(' weeks', 'w').replace(' week', 'w')
          .replace(' months', 'mo').replace(' month', 'mo');
        branchInfo += ` ${colors.gray}${shortTime}${colors.reset}`;
      }
      branchInfo += ')';

      ghSegments.push(`${colors.magenta}${branchInfo}${colors.reset}`);

      // CI from cache only — render path stays sync + fast
      if (ghAvailable()) {
        const runs = readCachedCI(repoPath);
        if (runs && runs.length > 0) {
          const run = runs[0];
          let statusIcon = '';
          let statusColor = colors.gray;
          if (run.status === 'completed') {
            if (run.conclusion === 'success') { statusIcon = '✅'; statusColor = colors.green; }
            else if (run.conclusion === 'failure') { statusIcon = '❌'; statusColor = colors.red; }
            else if (run.conclusion === 'cancelled') { statusIcon = '⚠️'; statusColor = colors.yellow; }
          } else if (run.status === 'in_progress') {
            statusIcon = '⏳'; statusColor = colors.yellow;
          }
          if (statusIcon) {
            ghSegments.push(`CI ${statusColor}${statusIcon}${colors.reset}`);
          }
        }
      }

      return ghSegments.join(` ${colors.gray}│${colors.reset} `);
    }

    // 1. Model
    const modelName = data.model?.display_name || data.model?.id || 'Claude';
    ccSegments.push(`${colors.cyan}${colors.bold}${modelName}${colors.reset}`);

    // 2. Current dir
    const currentDir = data.workspace?.current_dir || data.cwd || '';
    if (currentDir) {
      const currentDirName = path.basename(currentDir) || currentDir;
      ccSegments.push(`${colors.blue}${currentDirName}${colors.reset}`);
    }

    // 3. venv
    if (process.env.VIRTUAL_ENV) {
      const venvName = path.basename(process.env.VIRTUAL_ENV);
      ccSegments.push(`${colors.green}🐍 ${venvName}${colors.reset}`);
    }

    // 4. Context window usage (from pre-parsed transcriptEntries — F2.7)
    const modelId = data.model?.id || '';
    const modelDisplay = data.model?.display_name || '';
    // measure() is called directly, not through a null-collapsing wrapper: when it
    // refuses, the reason is logged rather than discarded. A segment that vanishes with
    // nothing written anywhere is the silent failure this whole change exists to end.
    const m = contextGauge && contextGauge.measure({ entries: transcriptEntries, modelId, modelDisplay });
    if (m && !m.ok) logErr('context-gauge-refused', new Error(m.reason));
    const g = m && m.ok ? m : null;
    if (g) {
      let tokenColor = colors.green;
      if (g.percentUsed >= 80) tokenColor = colors.red;
      else if (g.percentUsed >= 50) tokenColor = colors.yellow;
      ccSegments.push(`${tokenColor}📊 ${contextGauge.statusSegment(g)}${colors.reset}`);
    }

    // 5. Code changes
    if (data.cost?.total_lines_added || data.cost?.total_lines_removed) {
      const added = data.cost.total_lines_added || 0;
      const removed = data.cost.total_lines_removed || 0;
      if (added > 0 || removed > 0) {
        ccSegments.push(`📝 ${colors.green}+${added}${colors.reset}/${colors.red}-${removed}${colors.reset}`);
      }
    }

    // 6. Repo lines
    for (const repoPath of findTouchedRepos()) {
      const ghLine = generateGhLine(repoPath);
      if (ghLine) allGhLines.push(ghLine);
    }

    console.log(ccSegments.join(` ${colors.gray}│${colors.reset} `));
    for (const ghLine of allGhLines) console.log(ghLine);

  } catch (error) {
    logErr('top-level', error);
    try {
      const data = JSON.parse(input);
      console.log(data.model?.display_name || 'Claude');
    } catch (e) {
      logErr('fallback-parse', e);
      console.log('Claude');
    }
  }
}

// Only attach the stdin render path when run as the statusline script; when
// required as a module (unit tests), expose the pure classifier without reading
// stdin (which would otherwise keep the test process alive). (#509 AC5.2)
if (require.main === module) {
  process.stdin.on('data', chunk => input += chunk);
  process.stdin.on('end', renderStatusline);
}

module.exports = { is1MContext };
