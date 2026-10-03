#!/usr/bin/env bash
# claude/hooks/_lib-branch-issue.sh — shared helper sourced by hooks that derive
# the active Issue number from the worktree's branch name (#498 Stage 5 L1C F2).
#
# Defines:
#   derive_issue_num_from_branch [BRANCH]
#                                 echoes the issue number (digits only) for a
#                                 branch name of the form `solo/issue-N-...` or
#                                 `worktree-solo+issue-N-...`. With no argument it
#                                 derives from the current HEAD; with an explicit
#                                 BRANCH string it extracts from that (e.g. a
#                                 stash's non-HEAD origin branch). Echoes empty
#                                 string when not in a git repo, no branch, or the
#                                 branch doesn't match the convention.
#
# Sourced by: sst3-session-context-injector.sh, sst3-stage-order-gate.sh,
#             sst3-stash-guard.sh (#528 Stage-5 dedup), sst3-ralph-restart-counter.sh
#             (#568). Re-derive before relying on this list:
#             grep -l '_lib-branch-issue.sh"' claude/hooks/*.sh
# Mirrors the canonical solo-branch convention (sst3_utils.SOLO_BRANCH_RE /
# sst3-bash-utils.sh::sst3_solo_branch_alt, #509 AC6.5) — keep the anchored
# pattern below in sync with that canonical if the convention changes.

# The git-environment scrub has ONE home: _lib-repo-identity.sh. install.sh copies every
# `_lib-*.sh` into ~/.claude/hooks/ alongside the hooks in the same loop, so the sibling
# resolves at runtime wherever this file was installed. Sourcing it rather than repeating
# an `unset` list here is the #568 lesson: a per-site variable list drifts, and the
# three-variable copy that shipped there was defeated by a fourth variable one round later.
# shellcheck source=_lib-repo-identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-repo-identity.sh"

derive_issue_num_from_branch() {
  local branch issue_num
  # Optional $1 = an explicit branch string (e.g. a stash's "WIP on <branch>"
  # origin branch, which is NOT the current HEAD); with no arg, derive from the
  # current HEAD. (#528 Stage-5 dedup: generalised so the stash-guard can extract
  # from a non-HEAD stash branch and the stage-order-gate can drop its duplicated
  # local regex — the load-bearing solo-branch pattern lives in exactly one place.)
  if [[ $# -ge 1 ]]; then
    branch="$1"
  else
    # An inherited GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_COMMON_DIR /
    # GIT_OBJECT_DIRECTORY OVERRIDES the repository this resolves against, so the branch —
    # and therefore the issue number — comes from whatever repo the PARENT process was in.
    # Every hook sourcing this file then acts on the wrong issue while looking healthy
    # (dotfiles#569; doctrine AP #31).
    # Scrubbed HERE rather than at function entry because the explicit-branch path above
    # runs no git, so there is nothing to protect on it.
    #
    # Do NOT read this scrub as covering the CALLER. Every production call site of this
    # function is `X="$(derive_issue_num_from_branch ...)"` (verified #569 Stage 5: all six),
    # and a command substitution is a subshell — the unset dies with it. A hook that runs its
    # own git- or gh-derived command must call sst3_scrub_git_env at TOP LEVEL itself. Two
    # hooks were found relying on this transitively and reading the wrong repository; see the
    # SUBSHELL RULE in _lib-repo-identity.sh.
    sst3_scrub_git_env
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
  fi
  # Anchored to the solo / worktree-solo convention ONLY (the `^...solo[/+-]issue-`
  # prefix mirrors SOLO_BRANCH_RE). A bare `issue-N` on a non-solo branch
  # (e.g. `feature/issue-42`) must NOT yield a spurious issue number — that
  # would put a false issue number into every hook that sources this file.
  # (#509 Stage-5: 6th branch-matcher site unified.)
  issue_num="$(printf '%s' "$branch" | grep -oE '^(worktree-)?solo[/+-]issue-[0-9]+' | grep -oE '[0-9]+$' || printf '')"
  printf '%s' "$issue_num"
}
