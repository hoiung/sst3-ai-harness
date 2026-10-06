#!/usr/bin/env bash
# claude/hooks/_lib-repo-identity.sh — shared helper for resolving WHICH REPOSITORY a
# hook is acting for, and the per-repo key derived from it (dotfiles#568 Ralph round 3).
#
# WHY THIS EXISTS. #568 keyed the SessionStart resume pointer per repo so one session's
# handover could not be injected into another repo's session. The derivation was written
# inline in one hook and Ralph then found FOUR separate routes to the same collision, one
# per round:
#   R1 F1  basename(dirname(git-common-dir)) collided for same-named repos in different
#          parents (~/a/myrepo vs ~/b/myrepo).
#   R1 F2  inside a submodule that expression is the literal string "modules", so every
#          submodule of every repo shared one bucket.
#   R2 F-A inherited GIT_DIR / GIT_WORK_TREE override `git -C`, so the env decided the
#          identity instead of the cwd (AP #31).
#   R3     GIT_COMMON_DIR does the same to `rev-parse --git-common-dir` specifically, and
#          was missed by R2's three-variable scrub.
# Four rounds patching one call site is the "fix is at the wrong level" signal. A class
# sweep then showed 8 hooks run git identity probes and 7 scrubbed NOTHING — each fix's
# lesson had stayed local to the file it was applied in. So the derivation lives here now,
# once, and consumers source it. Modelled on _lib-branch-issue.sh, the existing shared-helper
# precedent in this directory (sourced by 5 hooks) for exactly this reason.
#
# Defines:
#   sst3_scrub_git_env          unset every GIT_* variable that can override `git -C`.
#   sst3_repo_root [CWD]        echo the absolute repository root for CWD (default $PWD),
#                               or empty when CWD is not in a git repo.
#   sst3_repo_key  [CWD]        echo a filesystem-safe key uniquely identifying that repo.
#
# Consumers: sst3-session-context-injector.sh, sst3-ralph-restart-counter.sh (#568);
#            sst3-stage-order-gate.sh, sst3-canonical-sync-guard.sh, sst3-stash-guard.sh,
#            _lib-branch-issue.sh (#569 — four of the five the #568 class sweep found and
#            deliberately left, tracked rather than dropped; #577 removed the fifth);
#            sst3-destructive-op-guard.sh (#577 AC 1.4 — its merged-branch check runs git);
#            sst3-canon-ff.sh (#577 sign-off — it fetches and fast-forwards the canon clone).
#
# SUBSHELL RULE — read this before deciding a hook is covered transitively.
# `sst3_scrub_git_env` unsets in the shell that CALLS it. Every helper here and in
# _lib-branch-issue.sh is invoked as `X="$(helper)"`, and a command substitution runs in a
# SUBSHELL: the unset dies with it and the calling shell keeps its inherited GIT_*. So
# "hook H sources a lib that scrubs" is NOT coverage. H is covered only if H itself calls
# sst3_scrub_git_env at TOP LEVEL, before its own first git-derived command.
# (#569 Stage 5 measured the failure: a hook that relied on a lib's subshell-scoped scrub
# ran `gh issue view` — git-derived, since gh resolves its repo from the git environment —
# and read another repository's issue body.)

# Each of these can redirect a probe away from `git -C <dir>`; a hook that derives repo
# identity without clearing them reads whatever repo the PARENT process was in.
#
# WHO EXPORTS THEM (measured, git 2.43.0, #569 Stage 5 — the earlier wording here named the
# pre-commit framework, which exports nothing; git is the exporter, and only on some paths):
#   commit from a plain clone     -> GIT_INDEX_FILE only, and RELATIVE (`.git/index`)
#   commit from a LINKED WORKTREE -> GIT_DIR *absolute* + GIT_INDEX_FILE absolute
#   `git submodule foreach`       -> GIT_DIR=.git
# The worktree row is why this is an ordinary condition here rather than an exotic one:
# CLAUDE.md mandates worktree-per-agent as the Stage-4 model, so every commit this framework
# makes runs hooks with an absolute GIT_DIR already exported.
# GIT_WORK_TREE / GIT_COMMON_DIR / GIT_OBJECT_DIRECTORY have no such producer; they stay in
# the unset list as defence-in-depth and because a caller may set them by hand.
# The five-variable form matches this repo's own precedent at
# test-fixtures/stage5-record-skip-542/run.sh (the majority 3-var idiom elsewhere is
# for probes against a KNOWN target, where identity is not being derived).
sst3_scrub_git_env() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
}

# Resolve the repository root, by the SHAPE of --git-common-dir:
#   */.git/modules/*  a submodule       -> its own working tree
#   */.git            clone or worktree -> the directory containing .git. This is the
#                                          worktree-aware case: --git-common-dir resolves a
#                                          linked worktree back to its MAIN clone, so a
#                                          worktree and its parent deliberately share one key.
#   anything else     bare / unusual    -> --show-toplevel, else the common dir itself
sst3_repo_root() {
  local cwd="${1:-$PWD}" common root
  [[ -d "$cwd" ]] || cwd="$PWD"
  sst3_scrub_git_env
  common="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || { printf ''; return 1; }
  common="$(cd "$cwd" && cd "$common" 2>/dev/null && pwd)" || { printf ''; return 1; }
  case "$common" in
    */.git/modules/*) root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '')" ;;
    */.git)           root="$(dirname "$common")" ;;
    *)                root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '')"
                      [[ -z "$root" ]] && root="$common" ;;
  esac
  [[ -n "$root" ]] || { printf ''; return 1; }
  printf '%s' "$root"
}

# Key = readable basename + a digest of the ABSOLUTE root path. The prefix keeps the file
# identifiable by eye; the digest is what makes collisions impossible, which the basename
# alone did not (R1 F1/F2). Without sha256sum, the whole sanitized path is used — verbose
# but still unique, because uniqueness is the invariant and brevity is only a convenience.
sst3_repo_key() {
  local cwd="${1:-$PWD}" root key
  root="$(sst3_repo_root "$cwd")" || { printf '_norepo'; return 0; }
  [[ -n "$root" ]] || { printf '_norepo'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    key="$(printf '%s' "$(basename "$root")" | tr -c 'A-Za-z0-9._-' '_')-$(printf '%s' "$root" | sha256sum | cut -c1-10)"
  else
    key="$(printf '%s' "$root" | tr -c 'A-Za-z0-9._-' '_')"
  fi
  [[ -z "$key" || "$key" == "-" ]] && key="_norepo"
  printf '%s' "$key"
}
