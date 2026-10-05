#!/usr/bin/env bash
# sst3-canonical-sync-guard.sh — F-9 canonical-clone-sync guard (#498 AC 3.1).
#
# WHAT  Claude Code PreToolUse Bash matcher. Fires on:
#         cargo build / cargo run / npm run build / sudo systemctl restart pb-*
#       Checks whether the canonical clone is fast-forward-aligned with
#       origin/main. If behind, WARN via additionalContext (the agent channel —
#       exit-0 stderr is debug-log only, dotfiles#577 AC 1.2) — the deploy will run against
#       stale source (canonical's local main does NOT auto-update from a
#       remote FF push; the runtime-feedback cost of that gap is captured in
#       feedback_worktree_sync_canonical_before_deploy.md).
#
# WHY   Operator-evidenced failure mode: after FF-pushing the worktree branch
#       onto origin/main, the canonical clone needs an explicit `git pull
#       --ff-only` before any `cargo build` / `sudo systemctl restart` —
#       skip the sync and the build picks up STALE code, looks identical to
#       "nothing was deployed".
#
# CONTRACT  stdin = PreToolUse JSON; `.tool_input.command` and `.cwd` read via jq; the
#       command is split by _lib-shellcmd.py (installed beside the hooks).
#       Fires only on a simple command `cargo build|run` / `npm run build` /
#       `[sudo] systemctl restart pb-...`, judged in the directory THAT command runs in.
#       Other commands → silent pass (a builtin substring pre-filter, so the degrade
#       notices below fire only on candidates). A repository with no origin remote →
#       silent (nothing to be behind). jq / git / the reader absent, or a directory the
#       reader cannot tell → exit 1 + JSON (operator systemMessage + agent
#       additionalContext; advisory, does NOT block).
#
# REVERSIBLE  Remove the PreToolUse Bash matcher entry from claude/settings.json.
set -uo pipefail

# GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_COMMON_DIR / GIT_OBJECT_DIRECTORY each
# OVERRIDE an explicit repo selection, and git hooks plus the pre-commit framework export
# them into child processes routinely. Unscrubbed, the canonical-root resolution below picks
# whatever repo the PARENT was in, so this guard reports another repo's staleness — or stays
# silent because THAT repo happens to be aligned — while the build really does run against
# stale source (dotfiles#569; doctrine AP #31). Scrubbed before ANY git call.
# shellcheck source=_lib-repo-identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-repo-identity.sh"
sst3_scrub_git_env

# shellcheck source=_lib-hook-output.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-hook-output.sh"

raw_stdin="$(cat 2>/dev/null || true)"
# Cheap pre-filter (bash builtin): only cargo / npm / systemctl commands can fire. Taken on the
# text with quotes and backslashes removed; an ANSI-C `$'…'` word always goes on (fix review 2).
raw_plain="${raw_stdin//[\'\"\\]/}"
[[ "$raw_plain" != *cargo* && "$raw_plain" != *npm* && "$raw_plain" != *systemctl* && "$raw_stdin" != *"\$'"* ]] && exit 0

degraded() { # <why the check could not run, e.g. "jq is not installed">
  printf 'F-9 canonical-sync-guard: %s.\n' "$1" >&2
  sst3_hook_emit PreToolUse \
    "F-9 canonical-sync-guard: $1, so the guard could not check whether the canonical clone is behind origin before this build/restart. Run git fetch and git status in the canonical clone yourself; if it is behind, pull --ff-only and rebuild." \
    "F-9 canonical-sync-guard: $1 — stale-source check skipped."
  exit 1
}
command -v jq >/dev/null 2>&1 || degraded 'jq is not installed'
command -v git >/dev/null 2>&1 || degraded 'git is not installed'
# An unparseable payload yields an empty CMD below, which would exit 0 as "nothing to check".
printf '%s' "$raw_stdin" | jq empty 2>/dev/null || degraded 'the hook payload is not valid JSON'

CMD="$(printf '%s' "$raw_stdin" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && exit 0
PAYLOAD_CWD="$(printf '%s' "$raw_stdin" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -n "$PAYLOAD_CWD" ]] || PAYLOAD_CWD="$PWD"

# Fire-list check, per simple command, in the directory each one runs in (#577 Stage 5
# fix review R38, the R33/R34 class): the guard used to match the whole text and judge
# the hook's own directory, so `cd /other/repo && cargo build` was checked against the
# session's repo and `echo 'cargo build'` counted as a build. _lib-shellcmd.py (beside
# the hooks) splits the command, unwraps sudo / sh -c, tracks `cd`; a directory it cannot
# tell is null. One output line per firing command: `+<directory>`, or `-` when unknown.
# unread_reason <reader output> — why part of the command could not be read (an opaque record),
# or empty. The caller then decides from the plain pattern on the quote-stripped text, as when
# the reader is missing (#577 Stage 5 fix review 2).
unread_reason() {
  printf '%s\n' "$1" | jq -r 'select(has("opaque")) | "part of the command only exists when it runs (" + .opaque + ")"' 2>/dev/null | head -n 1
}
lib="$(dirname "${BASH_SOURCE[0]}")/_lib-shellcmd.py"
unread=""
if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$lib" ]] \
   || ! recs="$(printf '%s' "$CMD" | python3 "$lib" commands --cwd "$PAYLOAD_CWD" 2>/dev/null)"; then
  unread="the shell-command reader could not run (python3 or $lib is missing, or it failed)"
else
  unread="$(unread_reason "$recs")"
fi
if [[ -n "$unread" ]]; then
  # Unread: the plain patterns, on the text with quotes and backslashes removed, decide
  # whether there is anything to say.
  plain="${CMD//[\'\"\\]/}"
  if [[ "$plain" =~ (^|[^[:alnum:]_-])cargo[[:space:]]+(build|run)([^[:alnum:]_-]|$) ]] \
     || [[ "$plain" =~ (^|[^[:alnum:]_-])npm[[:space:]]+run[[:space:]]+build([^[:alnum:]_-]|$) ]] \
     || [[ "$plain" =~ (^|[^[:alnum:]_-])sudo[[:space:]]+systemctl[[:space:]]+restart[[:space:]]+pb- ]]; then
    degraded "$unread"
  fi
  exit 0
fi
fire_dirs="$(printf '%s\n' "$recs" | jq -r '
  (.argv // []) as $a | ($a[0] // "" | split("/") | last) as $t
  | ([$a[1:][] | select(startswith("-") or startswith("+") | not)]) as $w
  | select(($t == "cargo" and (($w[0] // "") | IN("build", "run")))
        or ($t == "npm" and $w[0:2] == ["run", "build"])
        or ($t == "systemctl" and ($a | index("restart")) != null and any($a[]; startswith("pb-"))))
  | if .cwd == null then "-" else "+" + .cwd end' 2>/dev/null | sort -u)"
[[ -z "$fire_dirs" ]] && exit 0

# check_dir <dir>: is the canonical clone of the repository <dir> is in behind origin?
# Always the canonical clone, not a worktree: it hosts the binary / live service.
check_dir() {
  local dir="${1#+}" common root default behind
  [[ "$1" == +?* ]] || degraded "the guard could not tell which directory the build/restart runs in (a cd it cannot follow)"
  common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [[ -n "$common" ]] || return 0
  if [[ "${common##*/}" == ".git" ]]; then root="${common%/.git}"; else root="$common"; fi
  # No origin remote: there is nothing to be behind (R38 — a fresh `cargo new` repo got
  # an instruction to fetch and pull from a remote it does not have).
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 0
  # Default branch, repo-agnostic and local-only: origin/HEAD, else main, else master.
  default="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  if [[ -z "$default" ]]; then
    if git -C "$root" show-ref --verify --quiet refs/remotes/origin/main; then default="main"
    elif git -C "$root" show-ref --verify --quiet refs/remotes/origin/master; then default="master"
    else
      # #577 Stage 5 H4: this was a silent exit 0, indistinguishable from "in sync".
      degraded "the canonical clone $root has an origin remote but no origin/HEAD, origin/main or origin/master (never fetched?)"
    fi
  fi
  # No fetch here (too slow for PreToolUse); a failed count is not "0 behind" (H4).
  if ! behind="$(git -C "$root" rev-list --count "HEAD..origin/$default" 2>/dev/null)" \
     || [[ ! "$behind" =~ ^[0-9]+$ ]]; then
    degraded "git could not count commits between HEAD and origin/$default in $root"
  fi
  if [[ $behind -gt 0 ]]; then
    printf 'F-9 canonical-sync-guard: canonical clone (%s) is %d commits behind origin/%s.\n' \
      "$root" "$behind" "$default" >&2
    printf '  The build/restart will run against STALE source.\n' >&2
    printf '  Suggested: git -C %s pull --ff-only origin %s\n' "$root" "$default" >&2
    sst3_hook_emit PreToolUse "F-9 canonical-sync-guard: the canonical clone ($root) is $behind commits behind origin/$default, so the build/restart you just ran used STALE source. Run git -C $root pull --ff-only origin $default, then rebuild or restart."
    exit 0
  fi
}
while IFS= read -r d; do check_dir "$d"; done <<< "$fire_dirs"

exit 0
