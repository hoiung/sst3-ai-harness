#!/usr/bin/env bash
# sst3-ralph-restart-counter.sh — Ralph restart counter (dotfiles#556 Phase 2).
#
# WHAT  Claude Code `SubagentStop` hook, registered with a matcher on
#       `ralph-review`. Observes Ralph tier dispatches and maintains a
#       deterministic per-issue RESTART count, so the number that governs the
#       bound in standards/stage-4/ralph-review.md stops being hand-written
#       prose and becomes a fact.
#
# WHY   `ralph_restarts` is recorded in most feedback files, carries three
#       incompatible meanings, and is parsed by nothing. Every statistic behind
#       the bound is a hand-count off that field. Making the count mechanical is
#       what makes λ — escalations per capped issue — measurable at all.
#       Derive the population rather than trusting a number written here; this
#       line carried a hardcoded "246" that was already 247 within the same
#       Issue that wrote it, and it climbs with every feedback file:
#         grep -rl ralph_restarts SST3-metrics/leader-feedback/ | wc -l
#
# LIMIT — READ THIS BEFORE ASSUMING IT ENFORCES ANYTHING.
#       The counter OBSERVES; the main agent ENFORCES. `SubagentStop` cannot
#       block or redirect the main agent's next dispatch, and `SubagentStart`
#       has no documented blocking capability. Nothing here can stop a 6th
#       restart. Enforcement is the main agent acting on the Phase-1 prose.
#       Canonical statement: standards/stage-4/ralph-review.md.
#
# THE COUNTING MODEL — `--restart` is the SOLE authority for the count.
#       All three tiers dispatch with the same `subagent_type=ralph-review`, so
#       a round that reaches Opus emits THREE SubagentStop events. Counting
#       events would over-count restarts by up to 3x, re-creating the exact
#       ambiguity Phase 0 removes.
#         * each qualifying event advances `tier_events_in_round` (1..3) and,
#           on overflow, ROUND — both purely for the audit trail;
#         * RESTARTS is moved by `open_new_round()` and nothing else, and that
#           is reachable ONLY from `--restart`;
#         * `--escalate` is the only reset within a stage; `--stage5` opens
#           Stage 5's own loop at Stage-5 entry (Stage 4's numbers are archived).
#       THERE IS NO EVENT-DERIVED FLOOR. Unsignalled, the count stays 0 no
#       matter how many events arrive — 9 ralph-review events still read 0.
#       An earlier draft of this header promised one ("the event model is the
#       floor that keeps the count non-zero if the agent forgets") and described
#       the 4th event as doing `restarts += 1`. Both were true once; the
#       inference was removed because it fabricated a phantom restart on every
#       re-run of a clean sequence and double-counted whenever the agent ALSO
#       signalled. The block at the foot of this file records that removal in
#       full — this header denied it for one commit, which is precisely the
#       "rule that states a check the code does not perform" class.
#       So: if the main agent does not signal, the number is wrong and nothing
#       will quietly cover for it. That is deliberate.
#
# CONTRACT
#       stdin (event mode) = SubagentStop event JSON. Fields used:
#         .agent_type  — gate; anything other than `ralph-review` is ignored.
#         .cwd         — the session's working directory. THIS WINS over the
#                        hook process's own CWD (see KEYING below).
#         .stop_hook_active — true on a continuation stop (the tier was sent back
#                        by a SubagentStop hook); ignored, already counted.
#       Flag modes read NO payload, so `</dev/null` is safe on them and only
#       on them. Never redirect stdin on an event-mode invocation: it discards
#       the JSON and the hook silently sees an empty payload.
#
# KEYING  State is keyed `<repo>-<issue>-<worktree>`.
#         `repo+issue` alone does NOT disambiguate two worktrees of the same
#         issue, which is the concurrency model CLAUDE.md mandates — two agents
#         on one issue would share a counter and each would read the other's
#         restarts. The worktree component is what keeps them separate.
#         WHICH CWD WINS: the stdin `.cwd` field, falling back to the hook
#         process's CWD only when absent. `_lib-branch-issue.sh` derives from
#         `git rev-parse` against the PROCESS cwd, which is the runtime's and
#         need not be the tree the agent is working in; the event's `.cwd` is
#         the authoritative session location. This is stated because AC 2.3
#         requires the precedence to be explicit rather than incidental.
#
# MODES
#   (stdin JSON)         observe one SubagentStop event
#   --print-state-path   print the resolved state file path
#   --print-log-path     print the resolved log file path
#   --restart            main agent signals a round boundary at fix time
#   --escalate           main agent signals the class-sweep escalation:
#                        restarts reset to zero, boundary logged
#   --get                print the current restart count (0 if no state)
#   --stage5             main agent signals Stage-5 entry (c4:T06, dotfiles#577):
#                        Stage 4's restarts + escalation are ARCHIVED into
#                        stage4_* fields and the loop state resets, so a scoped
#                        Stage-5 Ralph restart does not inherit Stage 4's terminal
#                        state. The KEY is unchanged: a new key would silently zero
#                        every in-flight issue's count (the #568 key change needed a
#                        migration). Idempotent: a second --stage5 keeps the archive.
#
# EXIT   0 normal. 2 = unknown mode. 3 = INERT (branch derivation failed) —
#        deliberately NOT a bare 0, so the boundary is visible instead of reading
#        as a silent success with a zero count (AC 2.4). 4 = state write FAILED —
#        the count was not persisted; do not read the previous value as current.
#        5 = state file CORRUPT — it exists but cannot be parsed; refused rather
#        than answered as 0, because a 0 here would silently reset the bound.
#        6 = a configuration knob is not a non-negative integer (see below).
#        THIS LIST IS THE CONTRACT. Every non-zero exit means "the number you
#        wanted does not exist" — never "the number is 0". Callers that read
#        --get MUST check the status; 3, 5 and 6 all print nothing on stdout.
#        (5 and 6 shipped before this line documented them. An undocumented
#        silent-no-count channel is the same defect as a silent zero.)
#
# REVERSIBLE  Remove the matcher entry from claude/settings.json.
set -uo pipefail

STATE_DIR="${SST3_RALPH_COUNTER_STATE_DIR:-$HOME/.claude/hooks/ralph-restart-state}"
LOG="${SST3_RALPH_COUNTER_LOG:-$HOME/.claude/hooks/ralph-restart-counter.log}"
LOG_MAX_BYTES="${SST3_RALPH_COUNTER_LOG_MAX_BYTES:-5242880}"
BOUND="${SST3_RALPH_RESTART_BOUND:-3}"
TIERS_PER_ROUND="${SST3_RALPH_TIERS_PER_ROUND:-3}"

# These three knobs are interpolated into arithmetic and `[[ -gt ]]`. Raw, they
# fail in three different silent-or-cryptic ways, all measured:
#   LOG_MAX_BYTES=0    the near-universal spelling for "no limit" — instead makes
#                      `sz -gt 0` true on EVERY write and `tail -c 0` emit
#                      nothing, so each append DESTROYS the whole audit history
#                      at exit 0 (5 restarts left 1 line of 6).
#   LOG_MAX_BYTES=5MB  `[[ -gt ]]` errors, rotation silently off forever.
#   LOG_MAX_BYTES=abc  `set -u` arithmetic kills the hook at a bare exit 1.
# A knob that cannot be parsed is a configuration error, not a value. It is
# refused loudly with its own exit code rather than being allowed to reach the
# arithmetic — where the failure surfaces as data loss instead of a message.
require_nonneg_int() { # <env-var-name> <value>
  if [[ ! "$2" =~ ^[0-9]+$ ]]; then
    printf 'RALPH-COUNTER BAD CONFIG: %s must be a non-negative integer, got %s. Refusing to run rather than reach the arithmetic, where this surfaces as lost data or a rotation that never fires.\n' \
      "$1" "${2:-<empty>}" >&2
    exit 6
  fi
}
require_nonneg_int SST3_RALPH_COUNTER_LOG_MAX_BYTES "$LOG_MAX_BYTES"
require_nonneg_int SST3_RALPH_RESTART_BOUND         "$BOUND"
require_nonneg_int SST3_RALPH_TIERS_PER_ROUND       "$TIERS_PER_ROUND"
# 0 parses but is still destructive for the log cap specifically, so it is given
# its meaning explicitly here rather than left to the rotation arithmetic.
if [[ "$LOG_MAX_BYTES" -eq 0 ]]; then
  LOG_ROTATE=0    # 0 == unlimited, the reading everyone expects
else
  LOG_ROTATE=1
fi
MATCH_AGENT="${SST3_RALPH_AGENT_TYPE:-ralph-review}"
# Read-only mode. An AC verification command is EXECUTED by every Ralph reviewer
# (the agent definition tells them "a command you did not run is not evidence"),
# and AC 2.1's verify pipes a real payload into this hook with the live cwd — so
# merely verifying the counter writes state: three spurious tier events per round,
# advancing `round` and polluting the audit trail the count is reconciled against.
# It can no longer move RESTARTS — that was the retired event-inference model, and
# this comment claimed it for one commit after the inference was removed. With
# this set the hook resolves and reports exactly as normal but persists nothing.
DRYRUN="${SST3_RALPH_COUNTER_DRYRUN:-0}"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib-branch-issue.sh"
# shellcheck source=/dev/null
[[ -r "$LIB" ]] && . "$LIB"

# ---------------------------------------------------------------- observability
# AP #12: every decision boundary emits a structured line AT WRITE TIME. The
# `audit "<event>"` calls below are the list of boundaries; it grows with the
# hook (the continuation stop and --stage5 came after it was first written), so
# it is not restated here. The restart-BOUND -> escalation boundary is the event
# whose frequency this whole Issue exists to measure — unlogged, it is written
# to nothing and λ stays at n=1 forever.
audit() {
  local event="$1" detail="$2"
  # AUDIT_RESTARTS lets a caller log the value that was TRUE AT THE BOUNDARY
  # rather than the value the variable happens to hold afterwards. Without it,
  # `escalation-boundary` — the one line λ is computed from — always recorded
  # restarts=0, because the reset had already happened by the time it was logged.
  # The number then survived only inside free-text `detail=`, where no parser
  # looks. A measurement this Issue exists to produce cannot live in prose.
  local r="${AUDIT_RESTARTS:-${RESTARTS:-0}}"
  if [[ "$DRYRUN" != "0" ]]; then
    printf '[dry-run] would log event=%s key=%s restarts=%s round=%s tier_events=%s detail=%s\n' \
      "$event" "${KEY:-unresolved}" "$r" "${ROUND:-0}" "${TIER_EVENTS:-0}" "$detail"
    return 0
  fi
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  # Rotate-then-append is ONE critical section, taken under an exclusive lock.
  # Unlike STATE_FILE (keyed per repo-issue-worktree) $LOG is machine-GLOBAL, so
  # every concurrent Ralph session on the box appends to this one file. A
  # tail-then-mv rotation without a lock silently discards whatever another
  # session appended between the read and the rename: measured at 2 of 40 event
  # lines surviving under forced rotation, against 40 of 40 with rotation off.
  # Losing audit lines corrupts exactly the trail AC 2.8 exists to produce, and
  # a per-process temp name alone does NOT fix it — the race is the read/rename
  # window, not the temp filename.
  # Returns non-zero when the record did not land. The append used to end in
  # `|| true`, so audit() could not fail: with $LOG unwritable the hook exited 0
  # with nothing on stdout or stderr, while the state channel exited 4 and said
  # WRITE FAILED for the byte-identical condition. That mattered because
  # `bound-reached` is the ONLY announcement that the bound was reached and
  # `escalation-boundary` is the line lambda is computed from — both could vanish
  # in silence. The channel-invariant block below says this hook writes TWO files
  # and the invariants apply to both; for one commit they applied to one.
  #
  # DELIBERATE ASYMMETRY — audit failure is LOUD but the process still exits 0,
  # where a state failure exits 4. This diverges from the escalation sweep's
  # recommendation ("loud on stderr AND non-zero") on purpose:
  #   - a failed STATE write means THE COUNT IS WRONG, so the caller must not
  #     trust the number and a non-zero exit is the only safe answer;
  #   - a failed AUDIT write means the TRAIL is incomplete while the count is
  #     perfectly correct. Exiting non-zero there would make a restart that was
  #     recorded correctly look like it failed, and the agent's documented
  #     response to a non-zero counter is to distrust the count — trading a
  #     missing log line for a wrong number. That is the worse failure.
  # What the sweep was actually right about is SILENCE, and silence is gone. The
  # invariant is "never fail silently", not "always exit non-zero".
  _audit_write() {
    if [[ "$LOG_ROTATE" -eq 1 && -f "$LOG" ]]; then
      local sz
      sz="$(wc -c <"$LOG" 2>/dev/null || printf '0')"
      if [[ "$sz" =~ ^[0-9]+$ && "$sz" -gt "$LOG_MAX_BYTES" ]]; then
        local tmp="$LOG.$$.tmp"
        # `tail -c` cuts on a BYTE boundary, so the first surviving line is
        # usually a fragment. Drop it: a half-line in an audit trail is not a
        # record, and a reader grepping `event=` would silently skip it anyway
        # while it still occupied the byte budget.
        # Rotation must be able to FAIL rather than silently truncate: the old
        # `&& mv || rm || true` chain could not tell "rotated" from "destroyed".
        # Deliberately NOT gated on the result being non-empty. Refusing to
        # rotate when nothing survives would let a log with no record boundaries
        # grow without limit — trading a size cap for data that is already
        # unreadable. An empty result means the tail window held no complete
        # record, and discarding it IS correct. What must not be weak is the
        # TEST: asserting only that the file shrank passes a rotation that throws
        # everything away, so the case asserts surviving records instead.
        if tail -c "$((LOG_MAX_BYTES / 2))" "$LOG" 2>/dev/null | sed '1{/^ts=/!d}' >"$tmp" 2>/dev/null &&
           mv "$tmp" "$LOG" 2>/dev/null; then
          :
        else
          rm -f "$tmp" 2>/dev/null || true
          printf 'RALPH-COUNTER AUDIT ROTATION FAILED: could not rotate %s; the existing trail was left intact and this record may be appended past the cap.\n' \
            "$LOG" >&2
        fi
      fi
    fi
    printf 'ts=%s event=%s key=%s restarts=%s round=%s tier_events=%s detail=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "${KEY:-unresolved}" \
      "$r" "${ROUND:-0}" "${TIER_EVENTS:-0}" "$detail" \
      >>"$LOG" 2>/dev/null || {
        printf 'RALPH-COUNTER AUDIT WRITE FAILED: could not append event=%s to %s. The measurement trail is INCOMPLETE — do not read its absence as "the boundary was not reached".\n' \
          "$event" "$LOG" >&2
        return 1
      }
  }
  # flock is util-linux and present on every target platform, but the audit trail
  # must never be the reason a hook fails, so an absent flock degrades to the
  # unlocked path rather than dropping the line entirely.
  # EVERY route to an unlocked write is announced. There are three, and only two
  # used to be: `flock` returning non-zero was `|| true`'d, and the
  # cannot-open-lockfile branch fell through to an unlocked write saying nothing.
  # An unlocked append is not a failure — the record still lands — but it is a
  # DEGRADED mode that can lose concurrent lines, and a degradation nobody is told
  # about is indistinguishable from correct operation.
  local unlocked_reason="" wrote=0 rc=0
  if ! command -v flock >/dev/null 2>&1; then
    unlocked_reason="flock unavailable"
  else
    local lockfd
    # The redirect is scoped to a GROUP, never written as `exec ... 2>/dev/null`.
    # `exec` with no command applies its redirections to the shell PERMANENTLY, so
    # that spelling silences every later stderr write — including the INERT warning
    # and the WRITE FAILED message. It shipped that way for one commit and the
    # INERT positive control caught it: the counter still exited 3, but said
    # nothing, which is precisely the silent-failure mode AC 2.4 forbids.
    if { exec {lockfd}>>"$LOG.lock"; } 2>/dev/null; then
      flock "$lockfd" 2>/dev/null || unlocked_reason="flock failed on $LOG.lock"
      # The write happens HERE whether or not flock succeeded — the fd is open
      # either way. `wrote` stops the announcement branch appending a duplicate
      # record, which is what a naive "announce then write" would do.
      _audit_write || rc=1
      wrote=1
      { exec {lockfd}>&-; } 2>/dev/null || true
    else
      unlocked_reason="cannot open $LOG.lock"
    fi
  fi
  if [[ -n "$unlocked_reason" ]]; then
    # Announced on stderr only — NOT through audit(), which would recurse.
    printf 'RALPH-COUNTER AUDIT UNLOCKED: %s; concurrent audit lines may be lost.\n' \
      "$unlocked_reason" >&2
  fi
  if [[ "$wrote" -eq 0 ]]; then
    _audit_write || rc=1
  fi
  return "$rc"
}

# ------------------------------------------------------------------- flag modes
# These read NO payload. Only `--print-log-path` runs here: the log path is
# machine-global, so it resolves even when the key does not. `--print-state-path`
# is deliberately NOT in this block — a state path is meaningless without a key,
# so it sits after the INERT gate and exits 3 there. (This comment previously said
# "`--print-*` ... run before the INERT gate", describing a symmetry that does not
# exist and sending readers looking for a second case arm here.)
case "${1:-}" in
  --print-log-path) printf '%s\n' "$LOG"; exit 0 ;;
esac

# ------------------------------------------------------------------------ input
# Flag modes take no stdin; event mode consumes it. Reading stdin on a flag mode
# would block on a terminal, so it is gated on the mode.
MODE="${1:-event}"
RAW=""
if [[ "$MODE" == "event" ]]; then
  RAW="$(cat 2>/dev/null || true)"
fi

json_field() { # <field> — no jq dependency; the payload is a flat event object.
  local f="$1"
  printf '%s' "$RAW" |
    grep -oE "\"$f\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
    head -1 |
    sed -E "s/.*:[[:space:]]*\"([^\"]*)\"$/\1/"
}

AGENT_TYPE=""
EVENT_CWD=""
STOP_ACTIVE=""
if [[ -n "$RAW" ]]; then
  AGENT_TYPE="$(json_field agent_type)"
  [[ -z "$AGENT_TYPE" ]] && AGENT_TYPE="$(json_field subagent_type)"
  EVENT_CWD="$(json_field cwd)"
  # A JSON boolean, so not a json_field string match.
  [[ "$RAW" =~ \"stop_hook_active\"[[:space:]]*:[[:space:]]*true ]] && STOP_ACTIVE=true
fi

# stdin `.cwd` WINS; the process CWD is the documented fallback only.
WORK_CWD="${EVENT_CWD:-$PWD}"
[[ -d "$WORK_CWD" ]] || WORK_CWD="$PWD"

# ------------------------------------------------------------------------ keying
# GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_COMMON_DIR / GIT_OBJECT_DIRECTORY all
# OVERRIDE an explicit `git -C`, and git hooks + the pre-commit framework export them into
# child processes as a matter of course. Unscrubbed, the probes below resolve whatever repo
# the PARENT was in, so a restart signalled in repo B increments repo A's counter — the
# bound this counter exists to enforce then silently tracks the wrong issue. Found by the
# dotfiles#568 class sweep, which showed 8 hooks probing git identity and 7 scrubbing none.
# The key SHAPE is deliberately unchanged here: re-keying would orphan in-flight counters.
# shellcheck source=_lib-repo-identity.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib-repo-identity.sh"
sst3_scrub_git_env

REPO_NAME=""
WORKTREE_NAME=""
ISSUE_NUM=""
if COMMON_DIR="$(git -C "$WORK_CWD" rev-parse --git-common-dir 2>/dev/null)"; then
  COMMON_DIR="$(cd "$WORK_CWD" && cd "$COMMON_DIR" 2>/dev/null && pwd)" || COMMON_DIR=""
  # dotfiles#568: was `basename(dirname(COMMON_DIR))`, which is the R1-F1 formula — two
  # unrelated repos sharing a leaf name in different parents produced the SAME key, so
  # their restart counters co-mingled. Ralph reproduced it here after the injector was
  # fixed, because the fix had been applied at one call site instead of to the class.
  # Now uses the shared collision-resistant derivation; existing state files were migrated.
  REPO_NAME="$(sst3_repo_key "$WORK_CWD")"
  [[ "$REPO_NAME" == "_norepo" ]] && REPO_NAME=""
  TOP="$(git -C "$WORK_CWD" rev-parse --show-toplevel 2>/dev/null || printf '')"
  [[ -n "$TOP" ]] && WORKTREE_NAME="$(basename "$TOP")"
  BRANCH="$(git -C "$WORK_CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
  if declare -F derive_issue_num_from_branch >/dev/null 2>&1; then
    ISSUE_NUM="$(derive_issue_num_from_branch "$BRANCH")"
  fi
fi

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._+-' '_'; }

KEY=""
if [[ -n "$REPO_NAME" && -n "$ISSUE_NUM" && -n "$WORKTREE_NAME" ]]; then
  KEY="$(sanitize "$REPO_NAME")-$(sanitize "$ISSUE_NUM")-$(sanitize "$WORKTREE_NAME")"
fi

# ------------------------------------------------------------------- INERT gate
# AC 2.4. feedback-voice-staging-55.md:96 records three hooks silently skipping on a
# 23-restart issue because the branch name did not conform. A counter that
# quietly reports zero is worse than no counter: it reads as "no restarts yet"
# and the bound never appears to be approached. So this path is LOUD (stderr)
# and exits 3, never a bare 0.
if [[ -z "$KEY" ]]; then
  audit "inert" "branch-derivation-failed cwd=$WORK_CWD repo=${REPO_NAME:-none} issue=${ISSUE_NUM:-none} worktree=${WORKTREE_NAME:-none}"
  printf 'RALPH-COUNTER INERT: cannot derive <repo>-<issue>-<worktree> from cwd=%s (repo=%s issue=%s worktree=%s). The restart count is NOT being tracked for this session — do not read a zero here as "no restarts". Expected a solo/issue-N-* or worktree-solo+issue-N-* branch inside a git repo.\n' \
    "$WORK_CWD" "${REPO_NAME:-none}" "${ISSUE_NUM:-none}" "${WORKTREE_NAME:-none}" >&2
  exit 3
fi

STATE_FILE="$STATE_DIR/$KEY.json"
STATE_LOCK="$STATE_FILE.lock"

# ---------------------------------------------------- state-channel invariants
# This hook writes TWO files: the audit log and the state file. Three integrity
# invariants apply to both, and each was historically fixed only at the site that
# produced that round's finding — which is why five rounds of instance-fixing kept
# yielding new instances of one class:
#
#   (i)   a failed write must be loud and non-zero      (round 4, write_state only)
#   (ii)  a shared file must be locked across the whole
#         read-modify-write, not just the write          (round 5, $LOG only)
#   (iii) a state value must never silently read zero    (AC 2.4, derivation only)
#
# They are now applied to the state channel as a channel. Do not fix the next
# instance in isolation; extend the invariant.

# (ii) — the state file is a read-modify-write channel. write_state()'s atomic mv
# makes each individual write all-or-nothing; it does nothing about two processes
# that both read 4 and both write 5. Measured before this lock: 50 concurrent
# --restart landed on 2 (sequential control: 50). The audit log got its own flock
# in round 5 for exactly this reason and the state file — the load-bearing one —
# was left out. Locking one of the two files a hook writes is not a locked hook.
# The lock is held for the process lifetime (this script is short-lived) and is
# released by exit; there is no unlock path to forget.
lock_state() {
  [[ "$DRYRUN" != "0" ]] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  local reason=""
  if ! command -v flock >/dev/null 2>&1; then
    reason="flock unavailable (install util-linux)"
  # Group-scoped so the redirection applies to this compound only. A bare
  # `exec {fd}>>file 2>/dev/null` applies to the SHELL and permanently silences
  # its stderr — that mistake muted the INERT and WRITE-FAILED warnings in round 5.
  elif { exec {STATE_LOCK_FD}>>"$STATE_LOCK"; } 2>/dev/null; then
    # THE THIRD UNLOCKED PATH. This was `|| true`, so a failing flock left the
    # hook running unlocked at exit 0 with nothing on stderr and no audit line —
    # silently reinstating the lost-update race measured at 50 concurrent
    # --restart landing on 2. Two of the three routes to "unlocked" were
    # announced and this one was swallowed, which is the same one-site-short
    # sweep this Issue keeps reproducing. flock(2) genuinely fails on
    # filesystems without lock support, and STATE_DIR is operator-overridable.
    flock "$STATE_LOCK_FD" 2>/dev/null || reason="flock failed on $STATE_LOCK"
  else
    reason="cannot open lock file $STATE_LOCK"
  fi
  # ONE emit site for this event, deliberately. Two call sites producing a single
  # event token is the paired-emit-surface class (AP #24) the boundary-site
  # inventory below exists to catch: neutering either one leaves the other still
  # emitting the token, so both mutants survive. It also made the flock-absent
  # branch untestable without a fake PATH — folding the two into one reason
  # variable leaves a single site with a single, reachable trigger.
  if [[ -n "$reason" ]]; then
    audit "unlocked-degraded" "$reason — concurrent updates for this key may be lost"
    printf 'RALPH-COUNTER UNLOCKED: %s. Concurrent updates to %s may be lost and the restart count may UNDER-report.\n' \
      "$reason" "$STATE_FILE" >&2
  fi
}
lock_state

# Defaults for a key that has no state file yet. Declared BEFORE write_state so
# every writer — including --print-state-path's materialisation below — has a
# complete record to persist.
RESTARTS=0; ROUND=1; TIER_EVENTS=0; LAST_ESC="null"
# c4:T06 — the stage this loop belongs to, and Stage 4's final numbers once Stage 5
# opens (null until then). A pre-#577 state file has none of these: it is a Stage-4
# count, and absence is migration, never corruption.
STAGE=4; S4_RESTARTS="null"; S4_LAST_ESC="null"

# A FAILED WRITE MUST NOT REPORT SUCCESS. This function's return was previously
# unchecked at every call site, under `set -uo pipefail` with no errexit — so an
# unwritable state dir produced exit 0 while audit() went on to log the values
# this process BELIEVED it had persisted. The log then attested restarts=2 while
# the file on disk and `--get` both said 1. That is AC 2.4's silent-zero failure
# reproduced on the write side, and it corrupts the very measurement this hook
# exists to produce — a lying audit trail is worse than a missing one.
# The temp file is per-process: a fixed "$STATE_FILE.tmp" makes two concurrent
# hooks for one key clobber each other's partial write.
write_state() {
  local tmp
  if [[ "$DRYRUN" != "0" ]]; then
    printf '[dry-run] would persist restarts=%s round=%s tier_events=%s to %s\n' \
      "$RESTARTS" "$ROUND" "$TIER_EVENTS" "$STATE_FILE"
    return 0
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  tmp="$STATE_FILE.$$.tmp"
  if ! printf '{"key":"%s","restarts":%s,"round":%s,"tier_events_in_round":%s,"last_escalation_restart":%s,"stage":%s,"stage4_restarts":%s,"stage4_last_escalation_restart":%s}\n' \
        "$KEY" "$RESTARTS" "$ROUND" "$TIER_EVENTS" "$LAST_ESC" "$STAGE" "$S4_RESTARTS" "$S4_LAST_ESC" >"$tmp" 2>/dev/null ||
     ! mv "$tmp" "$STATE_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    printf 'RALPH-COUNTER WRITE FAILED: could not persist state to %s. The restart count was NOT updated — do not read the previous value as current. Check permissions on %s.\n' \
      "$STATE_FILE" "$STATE_DIR" >&2
    return 1
  fi
}

# (i) — --print-state-path is the FIFTH write site. It materialised state inline
# and returned the path with exit 0 even when the write failed, while the four
# write_state callers exited 4 under the identical condition. Round 4's remedy was
# stated as "all sites || exit 4"; this one was not a write_state caller, so the
# sweep passed straight over it. It now goes through the same guarded writer as
# everything else — which is the point of having one.
case "$MODE" in
  --print-state-path)
    [[ "$DRYRUN" != "0" ]] && { printf '%s\n' "$STATE_FILE"; exit 0; }
    [[ -f "$STATE_FILE" ]] || write_state || exit 4
    printf '%s\n' "$STATE_FILE"; exit 0 ;;
esac

# ------------------------------------------------------------------- state load
# (iii) — read_num could not tell "field absent" from "field corrupt" from a
# genuine 0, so it answered 0 for all three. A truncated or garbled state file
# therefore reported --get 0 at exit 0 with no warning on stdout, stderr, or in
# the audit log: the bound silently RESET, which is the one failure mode a bound
# must not have. AC 2.4 named the silent zero on the branch-derivation side; this
# is the same defect on the read side, and it is now refused the same way.
#
# An ABSENT file is not corruption — that is a fresh key, and the defaults above
# stand. Only a file that exists and cannot be parsed is refused.
state_corrupt() { # <detail>
  audit "state-corrupt" "$1 file=$STATE_FILE"
  printf 'RALPH-COUNTER STATE CORRUPT: %s in %s. Refusing to report a count — answering 0 here would silently reset the bound. Inspect the file, or delete it to start a fresh cycle.\n' \
    "$1" "$STATE_FILE" >&2
  exit 5
}
# Prints the value and returns 0; returns 1 for absent / non-numeric / negative.
# It must RETURN rather than exit: it is called inside a command substitution, and
# an exit there would kill only the subshell while the caller sailed on with an
# empty value — the silent-zero bug wearing a different hat.
read_num() { # <field>
  local raw v
  raw="$(grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[^,}]*" "$STATE_FILE" 2>/dev/null | head -1)"
  [[ -n "$raw" ]] || return 1
  v="${raw##*:}"; v="${v//[[:space:]]/}"; v="${v//\"/}"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$v"
}
# null|N for a field that may be ABSENT (-> null). Returns 1 when the field is present
# but unreadable in write_state's single-line shape — fail-closed, like LAST_ESC.
read_opt() { # <field>
  local v
  grep -q "\"$1\"" "$STATE_FILE" 2>/dev/null || { printf 'null'; return 0; }
  v="$(grep -oE "\"$1\"[[:space:]]*:[[:space:]]*(null|[0-9]+)[[:space:]]*[,}]" "$STATE_FILE" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//; s/[[:space:]]*[,}]$//')"
  [[ -n "$v" ]] || return 1
  printf '%s' "$v"
}
if [[ -f "$STATE_FILE" ]]; then
  RESTARTS="$(read_num restarts)"                || state_corrupt "field 'restarts' is missing, non-numeric, or negative"
  ROUND="$(read_num round)"                      || state_corrupt "field 'round' is missing, non-numeric, or negative"
  TIER_EVENTS="$(read_num tier_events_in_round)" || state_corrupt "field 'tier_events_in_round' is missing, non-numeric, or negative"
  # Fail-closed like its three read_num siblings above (#567 T3 E4): this
  # diff made LAST_ESC the sole discriminator of every terminal
  # observation, and the old bare-fallback turned a corrupt value into
  # `null` silently — then --restart PERSISTED the null, erasing the
  # escalation record at exit 0. The guard shape differs from read_num in
  # TWO ways (#567 re-review TC): `null` is a legal value here, and the
  # pattern is deliberately STRICTER — it requires the value's trailing
  # `,`/`}` on the SAME line, i.e. exactly the single-line JSON shape
  # write_state emits. A state file reformatted by hand (pretty-printed,
  # value on its own line) lands in state_corrupt even when the value is
  # a valid null/integer — fail-closed on a file this script did not
  # write, by design, since only write_state's shape is trusted state.
  # On a (writer-unreachable) duplicate-key file, `head -1` reads the
  # FIRST textual occurrence. An ABSENT field is the pre-#567 legacy
  # state shape (no escalation recorded) and stays null — absence is
  # migration, not corruption, matching the absent-file rule above.
  if grep -q '"last_escalation_restart"' "$STATE_FILE" 2>/dev/null; then
    LAST_ESC="$(grep -oE '"last_escalation_restart"[[:space:]]*:[[:space:]]*(null|[0-9]+)[[:space:]]*[,}]' "$STATE_FILE" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*//; s/[[:space:]]*[,}]$//')"
    [[ -n "$LAST_ESC" ]] || state_corrupt "field 'last_escalation_restart' is present but not readable as null or a non-negative integer in the single-line state shape write_state emits (a hand-reformatted state file also lands here — fail-closed by design)"
  else
    LAST_ESC="null"
  fi
  # c4:T06 — the Stage-5 scope fields, fail-closed the same way when present. Each
  # key is matched WITH its leading quote, so `"restarts"` never reads the
  # `stage4_restarts` field and `"last_escalation_restart"` never reads its archive.
  STAGE_RAW="$(read_opt stage)" || state_corrupt "field 'stage' is present but not readable as null or a non-negative integer"
  [[ "$STAGE_RAW" == "null" ]] && STAGE=4 || STAGE="$STAGE_RAW"
  S4_RESTARTS="$(read_opt stage4_restarts)" || state_corrupt "field 'stage4_restarts' is present but not readable as null or a non-negative integer"
  S4_LAST_ESC="$(read_opt stage4_last_escalation_restart)" || state_corrupt "field 'stage4_last_escalation_restart' is present but not readable as null or a non-negative integer"
fi

# Boundary 4: the restart-BOUND -> escalation boundary. Logged as soon as it is
# REACHED, not only when the agent acts on it, so a missed escalation is
# visible in the log as a reached-but-not-taken boundary.
note_bound() {
  if [[ "$RESTARTS" -ge "$BOUND" ]]; then
    # Post-escalation the old detail was WRONG: canon forbids a second escalation
    # (#567 Ralph T3 F3), so "next-restart-must-escalate" would instruct the very
    # violation the terminal state exists to stop. One call site, two details —
    # the site inventory pins the call, the detail names the correct duty.
    local nb_detail="restarts=$RESTARTS bound=$BOUND next-restart-must-escalate"
    if [[ "$LAST_ESC" != "null" ]]; then
      nb_detail="restarts=$RESTARTS bound=$BOUND post-escalation-second-escalation-FORBIDDEN stop-and-report"
    fi
    audit "bound-reached" "$nb_detail"
  fi
}

# RESTARTS is moved HERE AND NOWHERE ELSE, and this is reached only from the
# explicit --restart signal. The event model used to share it, which is what let
# a tier-event stream fabricate restarts nobody performed — see the event-mode
# block at the foot of this file for the three wrong counts that produced.
open_new_round() {
  RESTARTS=$((RESTARTS + 1))
  ROUND=$((ROUND + 1))
  TIER_EVENTS=0
}

case "$MODE" in
  --get)
    printf '%s\n' "$RESTARTS"; exit 0 ;;

  --restart)
    # #567 terminal-state observation: after an escalation, canon permits exactly
    # ONE further Ralph loop — a FAIL in it STOPS the loop (stop-and-report), it
    # does not restart. So EVERY --restart arriving with a recorded escalation is
    # the loop continuing PAST its terminal state — a LEVEL trigger, not an edge:
    # the first post-escalation restart crosses the boundary and each further one
    # keeps violating (#567 Ralph T3 F3 — an edge trigger announced only the
    # first, so escalate → restart ×4 read as one violation then silence). The
    # counter OBSERVES (it cannot veto the agent): the boundary is logged and
    # announced LOUDLY, and the count still moves, so the violation is visible
    # in both channels rather than silently normalised.
    TERMINAL_CROSSED=0
    if [[ "$LAST_ESC" != "null" ]]; then
      TERMINAL_CROSSED=1
    fi
    open_new_round
    # Audit only AFTER the write lands. Logging first would attest a restart that
    # was never persisted, which is exactly how the log came to disagree with disk.
    write_state || exit 4
    audit "restart" "explicit-signal-from-main-agent"
    if [[ "$TERMINAL_CROSSED" -eq 1 ]]; then
      audit "terminal-boundary-crossed" "restart-after-escalation last_escalation_restart=$LAST_ESC — canon permits ONE post-escalation loop then stop-and-report"
      printf 'RALPH-COUNTER TERMINAL BOUNDARY CROSSED: a restart was signalled AFTER an escalation (last_escalation_restart=%s). Canon (#567, stage-4/ralph-review.md) permits exactly ONE further Ralph loop after the escalation; a FAIL in it STOPS the loop with a report to the operator — it does not restart. Stop and report the outstanding findings with their classes.\n' \
        "$LAST_ESC" >&2
    fi
    note_bound
    exit 0 ;;

  --escalate)
    # AC 2.5. Canon says "resume Ralph with the restart count reset to zero".
    # The counter is STRUCTURALLY BLIND to the sweep itself — AC 2.2's matcher
    # deliberately excludes the escalation Workflow's own subagents so the sweep
    # does not inflate the very number it was triggered by. Without this explicit
    # reset the count would read 4,5,6 after the escalation while canon says
    # 1-3: wrong from the escalation onward. (#567: the cycle no longer repeats —
    # after the escalation exactly ONE further Ralph loop is permitted, then the
    # loop STOPS with a report; see the post-escalation-restart observation in
    # --restart above. The reset semantics here are unchanged.)
    # An escalation below the bound is not refused — the operator may sweep early,
    # and a hook must not veto the agent — but it IS recorded, because it resets
    # the count and would otherwise be indistinguishable from a bound-reached
    # escalation when λ is computed.
    # Deferred to AFTER write_state lands (#567 T3 S6d): this audit's detail
    # says "reset applied", so emitting it here — before the write can fail —
    # left a log attesting a reset that never landed, the exact defect the
    # persist-before-announce comment below records for the boundary line.
    BELOW_BOUND=0
    if [[ "$RESTARTS" -lt "$BOUND" ]]; then
      BELOW_BOUND=1
    fi
    # #567 Ralph T3 F3: canon permits ONE escalation per issue — a second
    # --escalate is the loop past its terminal state by the other door. Observed
    # (audit + loud stderr after the write lands), never vetoed; the reset still
    # applies so the telemetry keeps matching what the agent actually did.
    SECOND_ESC=0
    if [[ "$LAST_ESC" != "null" ]]; then
      SECOND_ESC=1
      PRIOR_ESC="$LAST_ESC"
    fi
    LAST_ESC="$RESTARTS"
    ESC_FROM="$RESTARTS"
    RESTARTS=0
    ROUND=1
    TIER_EVENTS=0
    # Reset is persisted BEFORE it is announced. The previous order logged the
    # escalation first, so a failed write left a log claiming the count had been
    # reset while the file still held the old value — the reset would then appear
    # to have happened and never be retried.
    write_state || exit 4
    if [[ "$BELOW_BOUND" -eq 1 ]]; then
      audit "escalation-below-bound" "restarts=$ESC_FROM < bound=$BOUND — reset applied, not a bound-reached escalation"
    fi
    # Logged with the PRE-reset value in the structured restarts= field, not just
    # in detail=. This is the line λ (escalations per capped issue) is computed
    # from; recording restarts=0 on it made every escalation look like it fired
    # from zero.
    AUDIT_RESTARTS="$ESC_FROM" audit "escalation-boundary" "resetting restarts=$ESC_FROM -> 0 bound=$BOUND"
    if [[ "$SECOND_ESC" -eq 1 ]]; then
      audit "second-escalation-observed" "canon permits ONE escalation per issue — prior last_escalation_restart=$PRIOR_ESC; reset applied anyway (observe, never veto)"
      printf 'RALPH-COUNTER SECOND ESCALATION OBSERVED: an escalation was signalled with one already recorded (prior last_escalation_restart=%s). Canon (#567, stage-4/ralph-review.md) permits ONE escalation, then ONE further Ralph loop, then stop-and-report — a second escalation is the loop past its terminal state. Stop and report the outstanding findings with their classes.\n' \
        "$PRIOR_ESC" >&2
    fi
    exit 0 ;;

  --stage5)
    # c4:T06 (dotfiles#577 AC 3.8). Stage 5 may run its own, scoped Ralph loop over
    # its fixes. Without this, that loop inherited Stage 4's state: a Stage 4 that
    # ended escalated read every Stage-5 --restart as TERMINAL BOUNDARY CROSSED, and
    # a Stage 4 that ended at the bound started Stage 5 already spent.
    # Idempotent — a second --stage5 (a resume after a compact) must not overwrite
    # the archive with Stage 5's own numbers.
    if [[ "$STAGE" -ge 5 ]]; then
      audit "stage5-already-entered" "stage=$STAGE — archive kept (stage4_restarts=$S4_RESTARTS stage4_last_escalation_restart=$S4_LAST_ESC)"
      exit 0
    fi
    S4_RESTARTS="$RESTARTS"; S4_LAST_ESC="$LAST_ESC"
    RESTARTS=0; ROUND=1; TIER_EVENTS=0; LAST_ESC="null"; STAGE=5
    # Persist before announcing, as --escalate does: a log line attesting an archive
    # that never landed is the defect the persist-before-announce rule exists for.
    write_state || exit 4
    audit "stage5-entry" "archived stage4_restarts=$S4_RESTARTS stage4_last_escalation_restart=$S4_LAST_ESC; the stage-5 loop starts at 0 (key unchanged)"
    exit 0 ;;

  event) ;;
  *)
    printf 'sst3-ralph-restart-counter: unknown mode %s\n' "$MODE" >&2
    exit 2 ;;
esac

# ----------------------------------------------------------------- event mode
# Boundary 1: is this a Ralph tier at all? The settings.json matcher already
# filters, but a mis-registration (or a runtime that does not honour matchers)
# would otherwise let the escalation sweep's own subagents inflate the count.
# Belt and braces, because a silently-wrong count is the failure this hook exists
# to remove.
if [[ -z "$RAW" ]]; then
  audit "ignored" "empty-payload (stdin redirected on an event-mode invocation?)"
  exit 0
fi
if [[ "$AGENT_TYPE" != "$MATCH_AGENT" ]]; then
  audit "ignored" "agent_type=${AGENT_TYPE:-none} != $MATCH_AGENT"
  exit 0
fi
# Boundary 2: a continuation stop. When a SubagentStop hook returns additionalContext
# (sst3-subagent-result-parser.sh, dotfiles#577 AC 1.2) the subagent runs one more turn and
# stops AGAIN with stop_hook_active=true. That is the same tier, already counted at its
# first stop — counting it too booked two tier events for one nudged tier (measured in the
# AC 1.2 live E2E: tier_events 1 then 2 for a single ralph-review dispatch).
if [[ "$STOP_ACTIVE" == "true" ]]; then
  audit "ignored" "stop_hook_active=true — the same tier stopping again after a SubagentStop hook sent it back; counted at its first stop"
  exit 0
fi

# Boundary 3: tier-event accounting. THE EVENT STREAM IS OBSERVATIONAL. It tracks
# the round shape for the audit trail and never moves RESTARTS.
#
# It used to infer a restart from event overflow, which contradicted the canon
# this hook enforces — stage-4/ralph-review.md states that the event stream cannot
# see a restart at all, which is the whole reason --restart is REQUIRED rather than
# optional bookkeeping. (That canon once said the stream "under-reports by up to
# 5x". It does not under-report: nothing is derived from it, so unsignalled the
# count is 0 at any event volume. The wording was corrected with this comment.)
# Inferring anyway bought nothing and produced three distinct wrong counts:
#
#   - a PHANTOM restart on every re-run of a clean sequence. tier_events was only
#     ever reset by --restart or --escalate, so after a passing round it sat at
#     TIERS_PER_ROUND and the next sequence's first event overflowed a new round.
#     Three consecutive clean PASS sequences, zero real restarts, a fully
#     compliant agent: --get reported 2. A Stage-5 re-verify or a post-merge
#     re-run each booked +1 against the bound.
#   - DOUBLE counting when a round emitted more than TIERS_PER_ROUND events AND
#     the agent also signalled --restart: 2 true restarts read as 4, breaching
#     the bound of 3 at the second.
#   - the two paths disagreeing about what a round is.
#
# Under-reporting silently is what the canon warns about; over-reporting silently
# is worse, because it fires the escalation early and burns the sweep. An
# instrument that does both depending on regime is not a floor, so it is gone.
if [[ "$TIER_EVENTS" -ge "$TIERS_PER_ROUND" ]]; then
  TIER_EVENTS=1
  ROUND=$((ROUND + 1))
  write_state || exit 4
  audit "round-opened" "derived-from-event-overflow round=$ROUND (observational — restarts unchanged at $RESTARTS)"
else
  TIER_EVENTS=$((TIER_EVENTS + 1))
  write_state || exit 4
  audit "tier-event" "tier_events_in_round=$TIER_EVENTS of $TIERS_PER_ROUND (observational — restarts unchanged at $RESTARTS)"
fi

exit 0
