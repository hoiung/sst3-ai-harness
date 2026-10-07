#!/usr/bin/env node
// _lib-context-gauge.js — the ONE context-occupancy measurement (dotfiles#568 Phase 3)
//
// WHAT  Computes how much of the model's context window a session is actually using,
//       from the session transcript's most recent assistant `usage` block. Two callers:
//         - `claude/statusline.js` requires it to render the 📊 segment.
//         - `claude/hooks/sst3-context-gauge-injector.sh` runs it as a CLI and injects
//           the resulting line at UserPromptSubmit, so the agent can READ the number.
//
// WHY   A rule cannot out-argue an available number. `<total_tokens>` is re-injected after
//       every tool result and looks like an answer, so the fix is to make the right number
//       equally available, not to restate the rule. (AP #32 carries the doctrine.)
//
// WHY HERE  One definition, one place: statusline.js requires this module rather than
//       keeping a second copy of the formula (AP #10).
//
// CONTRACT  Token COUNTS are authoritative — they come straight from the transcript's
//       usage block. The PERCENTAGE depends on the window, which on the transcript path
//       is inferred, so `windowSource` is returned alongside and the rendered line names
//       an inferred window. Callers must not present an inferred percentage as measured.
//
//       WHAT IT REFUSES (ok:false + a machine-readable reason, never a fallback to
//       `<total_tokens>`): a usage field present but not a number; a window assumption the
//       measured tokens disprove; a transcript whose newest usage predates a compact
//       boundary, and so describes a context that no longer exists.
//
//       WHAT IT DOES NOT REFUSE, stated because earlier drafts of this comment claimed
//       otherwise: a sentinel turn is SKIPPED, not refused — the scan continues past it to
//       the last turn that really describes the window, and only a transcript with nothing
//       else in it degrades to `no-assistant-usage`. An unrecognised model is measured
//       against an assumed 200K, not refused; refusing every unlisted id is what silently
//       killed the statusline segment for every pre-1M model.
//
//       The CLI always exits 0; an unmeasurable context must not break a user's prompt.
//
// WINDOW IDENTIFICATION — the known limit, stated because it cannot be closed here.
//       The statusline receives `model.id` in its envelope and that CAN carry the `[1m]`
//       marker. The transcript's `message.model` never does: measured across every
//       transcript on this machine, zero model ids carry it, and the transcript records
//       no other window/beta field. So on the injected path ONE_M_FAMILIES is the SOLE
//       discriminator, and a 1M-family id on a 200K plan is indistinguishable from the
//       same id on 1M until usage exceeds 200K and disproves it.
//
//       Hence: the window is a hypothesis, reported as one. `assumed` marks a default the
//       data may disprove (checked in measure()); `family` marks a 1M inference the data
//       cannot confirm below 200K. Only `marker` is authoritative.

const fs = require('fs');

// The window a turn actually occupies exceeds the reported usage by a roughly fixed
// preamble (system prompt, tool schemas), and the last transcript entry lags the live
// turn by one round-trip. Both constants were tuned against the statusline's rendering
// and are kept here so the two callers cannot drift apart.
const BASELINE_OVERHEAD = 6000;
const LAG_BUFFER_PERCENT = 0.05;

const ONE_M_LIMIT = 1_000_000;
const DEFAULT_LIMIT = 200_000;

const ONE_M_FAMILIES = ['opus-4-6', 'opus-4-7', 'opus-4-8', 'opus-5', 'sonnet-4-6', 'fable-5', 'sonnet-5'];

// The two window signals, each defined ONCE. resolveWindow must tell them apart (a marker
// is authoritative, a family match is not), while is1MContext only cares whether either
// fired — which is why the pair is factored out rather than one calling the other. An
// earlier revision inlined both tests into resolveWindow while is1MContext kept its own
// copy: the twin-drift class this module's header claims to have removed, reintroduced
// inside the module itself.
function hasOneMMarker(modelId = '', modelDisplay = '') {
  return /\[1m\]/i.test(modelId)
      || /\b1m\b/i.test(modelDisplay)
      || modelDisplay.includes('1M context');
}

function inOneMFamily(modelId = '') {
  return ONE_M_FAMILIES.some(m => modelId.includes(m));
}

function is1MContext(modelId = '', modelDisplay = '') {
  return hasOneMMarker(modelId, modelDisplay) || inOneMFamily(modelId);
}

// Claude Code writes stand-in assistant turns whose model is a sentinel rather than a
// real model — `<synthetic>` appears when you hit a rate limit. They carry no usage worth
// reading and must not be treated as the current state.
function isSentinelModel(modelId = '') {
  return modelId === '' || /^<.*>$/.test(modelId);
}

// Returns { limit, known, assumed, windowSource }.
//   windowSource 'marker'  — an explicit [1m]/1M signal. Authoritative.
//   windowSource 'haiku'   — every Haiku is 200K. Authoritative by family, no variant.
//   windowSource 'family'  — a 1M-capable family id with no marker. NOT confirmable
//                            below 200K of usage; see the header's known limit.
//   windowSource 'default' — anything else real: 200K, `assumed`, disprovable by measure().
//   known:false            — a sentinel or unusable id. Refuse.
function resolveWindow(modelId = '', modelDisplay = '') {
  if (hasOneMMarker(modelId, modelDisplay)) {
    return { limit: ONE_M_LIMIT, known: true, assumed: false, windowSource: 'marker' };
  }
  if (isSentinelModel(modelId)) {
    return { limit: null, known: false, assumed: false, windowSource: 'none' };
  }
  if (/haiku/i.test(modelId) || /haiku/i.test(modelDisplay)) {
    return { limit: DEFAULT_LIMIT, known: true, assumed: false, windowSource: 'haiku' };
  }
  if (inOneMFamily(modelId)) {
    return { limit: ONE_M_LIMIT, known: true, assumed: false, windowSource: 'family' };
  }
  return { limit: DEFAULT_LIMIT, known: true, assumed: true, windowSource: 'default' };
}

// Strict: a usage field that is present but not a finite, non-negative number means the
// schema is not what this code was written against. Returns undefined for "absent"
// (legitimately 0) and null for "present but invalid" (refuse to measure).
//
// `+` on a string CONCATENATES in JavaScript, so without this a transcript carrying
// "100" instead of 100 produced 6300105210096.6k rather than any kind of error.
function readTokenField(v) {
  if (v === undefined || v === null) return undefined;
  // The `typeof` test is a readability belt: it states the intent (a token count must BE a
  // number) that the finiteness test beside it only implies, so mutate_sweep.sh scores
  // dropping it `equivalent` and that verdict is correct rather than a coverage hole.
  // The ARGUMENT for why lives in that sweep's KNOWN_EQUIVALENT registry and not here —
  // the registry key is derived from the guard's own text, so it rots the moment this line
  // changes and forces the argument to be re-made. A second copy in this comment would not
  // (AP #9: of two statements of one fact, keep the one that self-invalidates).
  if (typeof v !== 'number' || !Number.isFinite(v) || v < 0) return null;
  return v;
}

// The three fields that make up context occupancy, read in ONE place. They were written
// out twice — the selection scan below and measure() further down — with nothing pinning
// them equal, which is the twin-drift class this module's header claims to have removed,
// present in the module itself for a third time. The sum site is well covered; the
// SELECTION site was not, so dropping a field there passed the whole suite. Live impact
// was nil on today's corpus (no turn is cache-write-only) and a coverage hole that depends
// on a corpus staying shaped as it is today is not closed, just dormant.
function usageFields(u) {
  return [u.input_tokens, u.cache_creation_input_tokens, u.cache_read_input_tokens]
    .map(readTokenField);
}

// How much of the transcript's END the first read takes. Transcripts only grow (a compact
// appends, it never truncates) and a long session's reaches hundreds of MB; decoding the
// whole file on every status-bar refresh and every prompt measured ~4 s of CPU and ~1.3 GB
// per call at 348 MB (dotfiles#578). The read widens itself when this is not enough.
const TAIL_WINDOW_BYTES = 2_097_152;

// Parse the END of a Claude Code transcript (JSONL): the last TAIL_WINDOW_BYTES, doubling
// backwards until the parsed suffix holds a usage entry lastAssistantUsage accepts, or the
// file start is reached. Returns that suffix, in file order.
//
// WHY A SUFFIX MEASURES THE SAME AS THE WHOLE FILE. measure() reads two things: the newest
// qualifying usage entry, and whether a compact boundary sits AFTER it. The suffix ends
// where the file ends, so its newest qualifying entry is the file's, and everything after
// that entry — any boundary that could refuse it included — is inside the suffix too. A
// boundary before it cannot change the verdict, and indices shift by a constant, so
// measure()'s comparison is unchanged. Cases (br)-(bv) pin it, and dotfiles#578 records
// the run against full parses of every large transcript on the host.
//
// WHY BYTES, NOT ONE STRING. Node cannot hold a string over 536,870,888 characters, so the
// whole-file readFileSync(..., 'utf8') this replaced threw past ~512 MB and the gauge went
// blank. Each step decodes only its own region, cut at a newline byte: 0x0A never occurs
// inside a multi-byte UTF-8 sequence, so the cut never splits a character. One readSync per
// region is a full read for a regular file below Linux's 2 GiB per-call cap.
//
// The first line of a region that does not start at byte 0 is TREATED as incomplete (it
// usually is; when the region happens to open exactly on a line start it is whole, and is
// carried all the same): it goes into the next, wider step, never parsed in this one. Other malformed lines are skipped
// rather than aborting the parse — a truncated final line is normal while a session is live.
//
// `onError(category, err)` is optional so statusline.js can route failures into its own
// rate-limited log while the hook stays silent. It exists so there is ONE parser: the two
// callers differ only in what they do about a bad line, which is not a reason to keep two
// copies of the loop.
function parseTranscriptTail(transcriptPath, onError) {
  const report = typeof onError === 'function' ? onError : () => {};
  if (!transcriptPath) return [];
  let fd;
  try {
    fd = fs.openSync(transcriptPath, 'r');
  } catch (e) {
    report('transcript-read', e);
    return [];
  }
  try {
    const size = fs.fstatSync(fd).size;
    let entries = [];
    let carry = Buffer.alloc(0);
    let end = size;
    for (let window = TAIL_WINDOW_BYTES; ; window *= 2) {
      const start = Math.max(0, size - window);
      const region = Buffer.alloc(end - start);
      fs.readSync(fd, region, 0, region.length, start);
      const buf = Buffer.concat([region, carry]);
      // Past the first newline when the region starts mid-file; the whole buffer is carried
      // when it holds no newline at all (indexOf -1 + 1 is 0, so `|| buf.length` takes over).
      const cut = start > 0 ? (buf.indexOf(0x0a) + 1 || buf.length) : 0;
      carry = buf.subarray(0, cut);
      const fresh = [];
      for (const line of buf.subarray(cut).toString('utf8').split('\n')) {
        if (!line.trim()) continue;
        try {
          fresh.push(JSON.parse(line));
        } catch (e) {
          report('transcript-jsonl-parse', e);
        }
      }
      entries = fresh.concat(entries);
      end = start;
      if (start === 0) return entries;
      if (lastAssistantUsage(entries)) return entries;
    }
  } catch (e) {
    report('transcript-read', e);
    return [];
  } finally {
    fs.closeSync(fd);
  }
}

// The LAST assistant entry carrying usage is the only one that describes the current
// window. Earlier entries describe smaller, already-superseded states.
//
// SENTINEL AND EMPTY TURNS ARE SKIPPED, not returned. Claude Code appends stand-in
// assistant turns — `<synthetic>` on a rate limit — that carry a real `usage` object
// summing to zero. Taking one as "the current state" is how the everyday hit-a-limit,
// come-back-later flow made the gauge go silent (or, worse, report a near-empty context
// on the turn after a limit). Scanning past them lands on the last turn that actually
// describes the window.
// A MALFORMED turn is returned, not skipped, so measure() can refuse on it. Skipping it
// would silently report an older, smaller turn as the current state — the same
// stale-reading defect the compact guard below exists to stop, arrived at from a different
// direction. `Number("abc") || 0` is 0, so the empty-turn test alone cannot tell a
// zero-usage turn from a garbage one; readTokenField can, and is the same test measure()
// applies, so the two cannot disagree about what "malformed" means.
function lastAssistantUsage(entries) {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (!entry || entry.type !== 'assistant' || !entry.message || !entry.message.usage) continue;
    const model = entry.message.model || '';
    if (isSentinelModel(model)) continue;
    const u = entry.message.usage;
    const fields = usageFields(u);
    if (fields.some(v => v === null)) return { usage: u, model, index: i };
    if (fields.reduce((a, v) => a + (v || 0), 0) <= 0) continue;
    return { usage: u, model, index: i };
  }
  return null;
}

// Claude Code marks a compaction in the transcript. Everything before it describes a
// context that no longer exists, so a reading taken from a pre-compact turn is not merely
// imprecise — it is describing a window that was discarded. Measured live: a session
// reporting 587.4k used immediately after a compact whose real occupancy was 87.9k.
//
// The error runs in the safe direction (it overstates usage, so it errs toward handing
// over), which is exactly why it needs a guard rather than tolerance: it reads as a
// confident instruction to hand over again, on the turn right after a handover.
function lastCompactBoundary(entries) {
  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (!entry) continue;
    if (entry.isCompactSummary === true) return i;
    if (entry.type === 'system' && entry.subtype === 'compact_boundary') return i;
  }
  return -1;
}

// Returns {ok:true, ...reading} or {ok:false, reason}. The reason is machine-readable so
// the injector can log WHY it went quiet — a silent mechanism with no detector is how the
// Phase 2 failure went unnoticed for two days.
function measure({ entries = [], modelId = '', modelDisplay = '' } = {}) {
  const found = lastAssistantUsage(entries);
  if (!found) return { ok: false, reason: 'no-assistant-usage' };

  // The newest usage predates a compaction, so it describes a discarded window. Refuse for
  // the one turn until the post-compact turn lands, rather than publish a figure already
  // known to be superseded.
  if (lastCompactBoundary(entries) > found.index) {
    return { ok: false, reason: 'usage-predates-compact' };
  }

  const u = found.usage;
  const fields = usageFields(u);
  if (fields.some(v => v === null)) return { ok: false, reason: 'usage-field-not-a-number' };

  const contextTokens = BASELINE_OVERHEAD + fields.reduce((a, v) => a + (v || 0), 0);
  if (!Number.isFinite(contextTokens) || contextTokens <= 0) {
    return { ok: false, reason: 'context-tokens-not-positive-finite' };
  }

  // The transcript's model wins when the caller did not supply one: the CLI has no
  // statusline envelope to read it from.
  const resolvedId = modelId || found.model;
  const win = resolveWindow(resolvedId, modelDisplay);
  if (!win.known) return { ok: false, reason: `unrecognised-model:${resolvedId || 'none'}` };

  const bufferedTokens = Math.round(contextTokens * (1 + LAG_BUFFER_PERCENT));

  // THE GUARD THAT REPLACES A LONGER ALLOWLIST. If the window was only assumed and the
  // measured context does not fit inside it, the assumption is disproved — by the data,
  // not by a list someone has to remember to update. Refusing here is what stops an
  // unrecognised 1M model reporting "-61% left"; keeping the 200K assumption otherwise is
  // what stops every pre-1M model losing its reading. A CONFIRMED window that overflows
  // is a different thing — a genuinely full context — and is clamped below, not refused.
  //
  // The operand is `contextTokens` for the same reason as `windowCaveat` below: an
  // assumption is disproved by measured occupancy, not by a projection about the next
  // turn. Against `bufferedTokens` every assumed-window model fell silent from 92.2% of
  // its window upward — the top of the window being the one stretch the gauge exists for.
  if (win.assumed && contextTokens > win.limit) {
    return { ok: false, reason: `window-assumption-contradicted:${resolvedId}` };
  }

  const percentUsed = Math.round((bufferedTokens / win.limit) * 100);
  if (!Number.isFinite(percentUsed)) return { ok: false, reason: 'percent-not-finite' };

  return {
    ok: true,
    contextTokens,
    bufferedTokens,
    tokenLimit: win.limit,
    windowSource: win.windowSource,
    percentUsed,
    // Clamped, not refused: a genuinely over-full window is a real state and the safe
    // direction to round is "no room left", which errs toward handing over.
    percentRemaining: Math.max(0, Math.min(100, 100 - percentUsed)),
    modelId: resolvedId,
  };
}

// There is deliberately no gauge()-style wrapper collapsing this to null. One existed for
// exactly one caller, edited in the same commit, and its only net effect was to throw away
// the `reason` field — so the statusline could not log a refusal even in principle, which
// is a silent fallback in a change whose entire point was making a silent failure visible.
// Both callers take the {ok, reason} shape and both report it.

function humanLimit(tokenLimit) {
  return tokenLimit >= ONE_M_LIMIT ? `${tokenLimit / ONE_M_LIMIT}M` : `${tokenLimit / 1000}K`;
}

// The injected sentence. It carries BOTH halves deliberately: the reading on its own did
// not stop the substitution, because `<total_tokens>` is still in the same context and
// still looks like an answer. Naming the wrong instrument next to the right one is what
// makes the choice unambiguous.
const DISCLAIMER =
  '<total_tokens> is a per-turn allowance that refills every message, never context (AP #32).';

// The token count is measured; the percentage rests on the window, and TWO of the four
// window sources are not authoritative. Both are qualified, with the alternative reading
// spelled out, because a percentage whose basis is a guess must not read as a measurement
// (the CONTRACT above). Only `marker` and `haiku` render plainly.
//
// Which way each one errs decides nothing about whether to say it — an unqualified
// number is quoted onward either way — but it is worth knowing: `family` overstates
// headroom up to 5x, `default` understates it up to 5x. Neither is disprovable below 200K,
// which is exactly the range where an agent is deciding whether it has room to continue.
// WHICH OPERAND DISPROVES A WINDOW. `contextTokens`, never `bufferedTokens`. A 200K window
// is ruled out by what is measurably IN the context, and `bufferedTokens` adds a 5% lag
// projection about a turn that has not happened yet. Comparing the projection crossed the
// threshold 15,524 tokens early: every reading with a real sum of 184,477..194,000 dropped
// the caveat while a 200K window still fitted the data, and that band is precisely where
// the alternative reading is 97-100% used. Padding must not be what settles a question
// about evidence.
function windowCaveat(m) {
  if (m.windowSource === 'family' && m.contextTokens <= DEFAULT_LIMIT) {
    const alt = Math.min(100, Math.round((m.bufferedTokens / DEFAULT_LIMIT) * 100));
    return ` (1M inferred from model id — unconfirmed below 200k; if this session is 200K you are at ${alt}% used)`;
  }
  if (m.windowSource === 'default') {
    const alt = Math.min(100, Math.round((m.bufferedTokens / ONE_M_LIMIT) * 100));
    return ` (200K assumed — this model id is in no known 1M family; if this session is 1M you are at ${alt}% used)`;
  }
  return '';
}

// The statusline's short form, HERE rather than there. It was hand-duplicated: the same
// `(tokens / 1000).toFixed(1)` in two files with nothing pinning them equal, so the k
// figure could drift between the injected line and the status bar — two different numbers
// for one session, across the exact two surfaces this Issue exists to reconcile. That
// halved the WHY HERE above: the measurement moved into this module, the presentation
// did not.
//
// It also carries the CONTRACT's other half. A `family` or `default` window is inferred,
// and the status bar had no room for the sentence `windowCaveat` returns — so it rendered
// an inferred percentage identically to a measured one, which the CONTRACT forbids in as
// many words. `~` before the percentage is the whole disclosure the width allows; the
// caveat sentence remains available to any caller that can afford it.
function statusSegment(m) {
  if (!m || !m.ok) return null;
  const inferred = windowCaveat(m) !== '';
  return `${(m.bufferedTokens / 1000).toFixed(1)}k (${inferred ? '~' : ''}${m.percentRemaining}% left)`;
}

function formatLine(m) {
  if (!m || !m.ok) {
    const reason = (m && m.reason) || 'no-readable-transcript';
    return `SST3 CONTEXT GAUGE: cannot measure (${reason}). Say so — do not substitute another number. ${DISCLAIMER}`;
  }
  return `SST3 CONTEXT GAUGE: ${(m.bufferedTokens / 1000).toFixed(1)}k of ${humanLimit(m.tokenLimit)} used — ${m.percentRemaining}% left${windowCaveat(m)}. This is the context reading; ${DISCLAIMER}`;
}

// Only what has a consumer: is1MContext (statusline.js re-export + statusline.test.js),
// parseTranscriptTail + measure (statusline.js and the gauge suite), formatLine (the CLI
// below), resolveWindow (the vocabulary enumerator in the gauge suite).
//
// ONE_M_FAMILIES is exported for the suite's DRIFT assertion, and for nothing else. Case
// (z) deliberately keeps its own frozen copy of the probe set — reading the live list
// instead makes a widened token part of the vocabulary the near-miss control checks
// against, and M8 and M11 then both survive (measured). The frozen copy is load-bearing;
// this export is what stops it going stale, by failing the moment the two disagree.
module.exports = {
  is1MContext,
  statusSegment,
  resolveWindow,
  parseTranscriptTail,
  measure,
  formatLine,
  ONE_M_FAMILIES,
};

if (require.main === module) {
  const transcriptPath = process.argv[2];
  const entries = parseTranscriptTail(transcriptPath);
  // The CLI NAMES the transcript it measured, because its output is otherwise shaped
  // exactly like the injected line and the documented way to obtain a path picks the newest
  // transcript on the machine — routinely another session's. `--injected` suppresses it for
  // the hook, which delivers the line into the very session it measured, where the path is
  // noise and the ambiguity cannot arise. Both halves are asserted (cases ah/ai).
  const injected = process.argv.includes('--injected');
  const suffix = (transcriptPath && !injected) ? ` [measured from: ${transcriptPath}]` : '';
  process.stdout.write(formatLine(measure({ entries })) + suffix + '\n');
  process.exit(0);
}
