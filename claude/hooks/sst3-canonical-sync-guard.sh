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
# CONTRACT  stdin = PreToolUse JSON; `.tool_input.command` read via jq.
#       Fires only on `cargo build|run` / `npm run build` /
#       `sudo systemctl restart pb-...`. Other commands → silent pass (a builtin
#       substring pre-filter, so the degrade notices below fire only on candidates).
#       jq absent / git absent → exit 1 + JSON (operator systemMessage + agent
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
# Cheap pre-filter (bash builtin): only cargo / npm / systemctl commands can fire.
[[ "$raw_stdin" != *cargo* && "$raw_stdin" != *npm* && "$raw_stdin" != *systemctl* ]] && exit 0

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

# Fire-list check — only these commands trigger.
FIRES=0
if [[ "$CMD" =~ (^|[^[:alnum:]_-])cargo[[:space:]]+(build|run)([^[:alnum:]_-]|$) ]]; then
  FIRES=1
elif [[ "$CMD" =~ (^|[^[:alnum:]_-])npm[[:space:]]+run[[:space:]]+build([^[:alnum:]_-]|$) ]]; then
  FIRES=1
elif [[ "$CMD" =~ (^|[^[:alnum:]_-])sudo[[:space:]]+systemctl[[:space:]]+restart[[:space:]]+pb- ]]; then
  FIRES=1
fi
[[ $FIRES -eq 0 ]] && exit 0

# Resolve canonical-clone root. Always operate from the canonical, not the
# current worktree — the gate is "is THE CANONICAL behind origin?", and the
# canonical is the path that hosts the binary / live service.
_common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common_dir" && "$_common_dir" != ".git" && "$_common_dir" != "./.git" ]]; then
  CANONICAL_ROOT="$(dirname "$_common_dir")"
else
  CANONICAL_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[[ -z "$CANONICAL_ROOT" ]] && exit 0

# Detect the canonical clone's default branch — repo-agnostic. Hardcoding
# origin/main makes the guard a no-op on master-based repos (e.g. dotfiles
# itself). Use `git symbolic-ref refs/remotes/origin/HEAD` (pure local op,
# no network), fall back to checking main then master if HEAD ref missing.
DEFAULT_BRANCH="$(git -C "$CANONICAL_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
if [[ -z "$DEFAULT_BRANCH" ]]; then
  # Fallback: probe main then master via show-ref (no network).
  if git -C "$CANONICAL_ROOT" show-ref --verify --quiet refs/remotes/origin/main; then
    DEFAULT_BRANCH="main"
  elif git -C "$CANONICAL_ROOT" show-ref --verify --quiet refs/remotes/origin/master; then
    DEFAULT_BRANCH="master"
  else
    exit 0  # No discernible default — silent skip (not a misconfiguration we can flag from here)
  fi
fi

# Check default-branch divergence — no fetch (would be too slow at PreToolUse;
# operator should periodically `git fetch` separately).
BEHIND="$(git -C "$CANONICAL_ROOT" rev-list --count "HEAD..origin/$DEFAULT_BRANCH" 2>/dev/null || echo 0)"
if [[ "$BEHIND" =~ ^[0-9]+$ ]] && [[ $BEHIND -gt 0 ]]; then
  printf 'F-9 canonical-sync-guard: canonical clone (%s) is %d commits behind origin/%s.\n' \
    "$CANONICAL_ROOT" "$BEHIND" "$DEFAULT_BRANCH" >&2
  printf '  The build/restart will run against STALE source.\n' >&2
  printf '  Suggested: git -C %s pull --ff-only origin %s\n' "$CANONICAL_ROOT" "$DEFAULT_BRANCH" >&2
  sst3_hook_emit PreToolUse "F-9 canonical-sync-guard: the canonical clone ($CANONICAL_ROOT) is $BEHIND commits behind origin/$DEFAULT_BRANCH, so the build/restart you just ran used STALE source. Run git -C $CANONICAL_ROOT pull --ff-only origin $DEFAULT_BRANCH, then rebuild or restart."
fi

exit 0
