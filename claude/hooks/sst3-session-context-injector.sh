#!/usr/bin/env bash
# sst3-session-context-injector.sh — SST3 SessionStart context injector (dotfiles#498 F-1)
#
# WHAT  Claude Code SessionStart hook (matchers: startup / resume / compact).
#       Emits a JSON envelope whose `additionalContext` carries 4 deterministic
#       fields the agent needs at session entry but historically forgot:
#         (a) verbatim operator task from the REPO-SCOPED resume pointer
#             ~/handover/current-task-<repo>.txt, if present
#         (b) active Issue + AC status (gh issue view --json title,body,labels)
#         (c) Reading Confirmation Checklist literal text
#         (d) post-compact mandatory re-read directive
#
# WHY   RC-1 (Prose-Rule Substrate Failure) + RC-2 (Memory-Pattern-Bias):
#       canon prose alone does not survive a compact. A SessionStart hook fires
#       at startup AND every post-compact resume, so the agent re-enters with
#       the literal mandatory-reading checklist in context rather than relying
#       on memory of having read it earlier. Zero context-window weight per
#       session beyond the emitted text itself.
#
# OUTPUT MODES
#   default (live)  Emits the Claude Code hook envelope:
#                     {"hookSpecificOutput":{"hookEventName":"SessionStart",
#                                            "additionalContext":"<flat str>"}}
#   --test          Emits a structured object form for jq verification:
#                     {"additionalContext":{
#                        "operator_task":"…",
#                        "active_issue":{…},
#                        "reading_checklist":["…","…",…],
#                        "post_compact_directive":"…"}}
#       Both forms always exit 0 — this hook is informational, never blocking.
#
# CONTRACT  jq must be available (install via <your-dotfiles-clone>/scripts/install.sh). gh may be
#       absent — graceful-degrade to a placeholder string for field (b).
#       The resume pointer may be absent — graceful-degrade likewise.
#
# REVERSIBLE  Remove the SessionStart hook block from claude/settings.json or
#       set `"disableAllHooks": true`. Zero residual state.
set -uo pipefail

MODE="${1:-live}"

# jq is a hard contract dependency (see CONTRACT above). Check it FIRST so the `.cwd`
# parse below can use it — a grep/sed parse of raw JSON mis-reads escaped quotes and
# nested keys, and there is no reason to hand-roll a parser when jq is already required.
if ! command -v jq >/dev/null 2>&1; then
  # Degraded path: never stall SessionStart, but SAY what was not loaded. An empty `{}` was
  # indistinguishable from "nothing to inject", so a post-compact session resumed with no
  # task, no Issue and no re-read directive and no word why (#577 Stage 5 H5). The text is
  # a fixed ASCII literal, so printf emits valid JSON without jq.
  DEGRADED_MSG='SST3 session context NOT loaded: jq is not installed, so the operator task, the active Issue and the post-compact reading list were not injected. Install jq (apt install jq). Until then read CLAUDE.md, STANDARDS.md and this repo pointer ~/handover/current-task-<repo>.txt yourself before acting.'
  if [[ "$MODE" == "--test" ]]; then
    printf '{"additionalContext":{"degraded":"%s"}}\n' "$DEGRADED_MSG"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$DEGRADED_MSG"
  fi
  exit 0
fi

# Resume pointer (dotfiles#510): lives under $HOME (NOT a literal `~`, which bash does
# not expand inside a ${VAR:-…} default) so it survives a WSL VM idle-reap / reboot,
# unlike the legacy /tmp location.
#
# REPO-SCOPED since dotfiles#568. It was ONE global file (`current-task.txt`) shared by
# every concurrent session in every repo: /handover overwrote it from whichever session
# compacted last, and SessionStart then injected that text into unrelated repos' sessions.
# Agents papered over it with `=== SESSION: <repo> ===` block headers inside the shared
# file; that fails the moment an agent reads past its own block, which is exactly what
# happened (a wrong context reading written by one session was echoed by three others).
# Keying by repo makes the isolation structural instead of a convention.
# Repo identity (root + per-repo key) lives in a SHARED helper, not inline here.
# dotfiles#568 Ralph found four separate routes to the same cross-repo collision by
# patching this derivation in place round after round (basename collisions, the submodule
# "modules" bucket, GIT_DIR/GIT_WORK_TREE override, then GIT_COMMON_DIR override). A class
# sweep showed 8 hooks run git identity probes and 7 scrubbed no GIT_* env at all — each
# fix's lesson had stayed local to the file it landed in. One definition, one place.
# shellcheck source=_lib-repo-identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-repo-identity.sh"

# Scrubbed HERE, at top level. `sst3_repo_key` and `derive_issue_num_from_branch` both scrub,
# but they are only ever called through `$( )`, and `unset` inside a command substitution runs
# in a subshell that cannot reach this shell. The `gh issue view` below therefore still saw an
# inherited GIT_DIR, and `gh` derives its repository from the git environment — so the issue
# TITLE and LABELS injected into the session came from the parent process's repository while
# the issue NUMBER came from this one (#569 Stage 5; measured with a recording `gh` shim).
sst3_scrub_git_env

# SessionStart delivers a JSON event on stdin whose `.cwd` is the session's directory.
# Prefer it; the hook's own $PWD is the documented fallback. Guarded on `! -t 0` so a
# terminal invocation (tests, manual probe) never blocks waiting for EOF.
HOOK_RAW=""
if [[ ! -t 0 ]]; then HOOK_RAW="$(cat 2>/dev/null || true)"; fi
EVENT_CWD="$(printf '%s' "$HOOK_RAW" | jq -r 'if type=="object" then (.cwd // empty) else empty end' 2>/dev/null || printf '')"
WORK_CWD="${EVENT_CWD:-$PWD}"
[[ -d "$WORK_CWD" ]] || WORK_CWD="$PWD"

# `_norepo` is a RESERVED key, not an accidental shared bucket: a session outside any git
# repo gets its own pointer. There is deliberately NO fallback to the legacy global path —
# that would re-open the exact bleed this issue closes.
REPO_KEY="$(sst3_repo_key "$WORK_CWD")"
[[ -n "$REPO_KEY" ]] || REPO_KEY="_norepo"

TASK_FILE="${SST3_CURRENT_TASK_FILE:-$HOME/handover/current-task-$REPO_KEY.txt}"

# (a) Verbatim operator task — preserved exactly as written; never paraphrased.
if [[ -r "$TASK_FILE" ]]; then
  OPERATOR_TASK="$(cat "$TASK_FILE" 2>/dev/null || printf '')"
else
  OPERATOR_TASK=""
fi

# (b) Active Issue + AC status. gh inferred from cwd; absent gh degrades cleanly.
ACTIVE_ISSUE_JSON='{}'
if command -v gh >/dev/null 2>&1; then
  # Branch name like worktree-solo+issue-498-foo or solo/issue-498-foo → issue #498.
  # Derivation lives in shared helper (#498 Stage 5 L1C F2 — AP #9 single-source).
  # shellcheck source=_lib-branch-issue.sh
  source "$(dirname "${BASH_SOURCE[0]}")/_lib-branch-issue.sh"
  ISSUE_NUM="$(derive_issue_num_from_branch)"
  if [[ -n "$ISSUE_NUM" ]]; then
    ACTIVE_ISSUE_JSON="$(gh issue view "$ISSUE_NUM" --json number,title,labels 2>/dev/null || printf '{}')"
    [[ -z "$ACTIVE_ISSUE_JSON" ]] && ACTIVE_ISSUE_JSON='{}'
  fi
fi

# (c) Reading Confirmation Checklist — literal text per CLAUDE.md.
# 7 items (dotfiles#528 AC 1.2): the post-compact full-re-read mandate (handover + active
# /Leader stage line-by-line) is the operator's #1-emphasis fix — it must appear in the
# checklist the agent re-enters with, not only in the prose directive (d).
READ_CHECKLIST_JSON="$(jq -nc --arg taskfile "$TASK_FILE" '[
  "Read STANDARDS.md",
  "Read ANTI-PATTERNS.md",
  "Read WORKFLOW.md",
  "Read project CLAUDE.md",
  "Read active Issue body line-by-line",
  ("Read the handover file IN FULL (if " + $taskfile + " present) — the whole file, not a skim"),
  "Re-read the active /Leader stage section of .claude/commands/Leader.md LINE-BY-LINE — a pre-compact read does not count"
]')"

# (d) Post-compact directive — fires at every resume, not just startup.
# dotfiles#528 AC 1.1: two explicit clauses added (handover-in-full + active /Leader stage
# line-by-line) — the operator's #1-emphasis fix. Multi-line so each clause is its own line:
# clause (a) matches `handover.*full`, clause (b) matches `line-by-line` (AC-1.1 verify >=2).
POST_COMPACT_DIRECTIVE="Post-compact recovery: re-read CLAUDE.md + STANDARDS.md + ANTI-PATTERNS.md + WORKFLOW.md + active Issue. Do NOT resume from memory — a pre-compact read does NOT survive a compact; memory is diluted and files change.
If $TASK_FILE is present, read the named handover file in full (the whole handover, line-by-line) before the first action — do not skim, do not assume it is already read.
Re-read the active /Leader stage section of .claude/commands/Leader.md line-by-line; only then resume, having re-read it."

# Build the additionalContext object.
CTX_OBJ="$(jq -nc \
  --arg task "$OPERATOR_TASK" \
  --argjson issue "$ACTIVE_ISSUE_JSON" \
  --argjson checklist "$READ_CHECKLIST_JSON" \
  --arg directive "$POST_COMPACT_DIRECTIVE" \
  '{operator_task:$task, active_issue:$issue, reading_checklist:$checklist, post_compact_directive:$directive}')"

if [[ "$MODE" == "--test" ]]; then
  # Test mode: emit structured form so AC 2.1 jq verification works.
  jq -nc --argjson ctx "$CTX_OBJ" '{additionalContext:$ctx}'
  exit 0
fi

# Live mode: flatten to string, wrap in Claude Code hook envelope.
FLAT="$(jq -nr --argjson ctx "$CTX_OBJ" '
  "=== SST3 Session Context ===\n" +
  "Operator task: " + ($ctx.operator_task // "(none captured)") + "\n" +
  "Active Issue: " + (($ctx.active_issue | tostring) // "(none)") + "\n" +
  "Mandatory reading:\n" + ($ctx.reading_checklist | map("  - " + .) | join("\n")) + "\n" +
  "Directive: " + $ctx.post_compact_directive')"

jq -nc \
  --arg flat "$FLAT" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$flat}}'
exit 0
