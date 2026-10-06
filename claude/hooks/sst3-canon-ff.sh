#!/usr/bin/env bash
# sst3-canon-ff.sh — fast-forward the runtime canon clone after a dotfiles push (dotfiles#577).
#
# WHAT  Claude Code PostToolUse Bash matcher. After a Bash call that ran `git push` in a
#       dotfiles checkout (the canon clone itself, one of its worktrees, or another clone
#       with the same origin), fetch origin in the canon clone and, when it is on origin's
#       default branch with no tracked changes, not ahead and strictly behind, run
#       `git merge --ff-only origin/<default>`. What it did, or why it did not, goes to the
#       agent (additionalContext) and the operator (systemMessage). Silent when the command
#       pushed nothing from a dotfiles checkout, or the clone is already current. Any push
#       from a dotfiles checkout fires it, not only one to the default branch: the clone only
#       ever moves to origin/<default>, so a feature-branch push leaves it as it was unless
#       someone else's push had already left it behind. A push whose directory the hook cannot
#       tell fires it too, and the messages say so.
#
# WHY   Every consumer's drift and SEC hooks read the canon from that clone and exit 2 while
#       it is behind origin ("shared dotfiles is on branch master, N behind"), and every
#       dotfiles master push leaves it behind (three times on 2026-10-05/06). The operator's
#       #577 sign-off ruling: the pushing agent fast-forwards it, under the conditions above.
#
# SAFETY  It runs `git fetch origin` there (remote-tracking refs and FETCH_HEAD only) and moves
#       the clone only by `git merge --ff-only`; it never checks out, switches, resets or
#       stashes. A clone on another branch (ruling 11: the operator, or the session that moved
#       it, returns it), with tracked changes, or ahead of origin is left as it is and named.
#       Untracked files from other sessions are fine; git refuses if an incoming commit would
#       overwrite one.
#
# CANON CLONE  Where ~/.claude/commands links into, the same resolution as
#       sst3-branch-guard.sh canon_clone(); SST3_CANON_CLONE overrides it (tests). No
#       symlinked install means no runtime canon: silent.
#
# LIMIT A push started with run_in_background may still be running when this hook fires;
#       the clone is then current up to whatever origin had. The next push catches up.
#
# CONTRACT  stdin = PostToolUse JSON; `.tool_input.command` and `.cwd` read via jq. The
#       command is split by _lib-shellcmd.py (beside the hooks); when it cannot be read and
#       the text names git push, the clone is checked anyway, since the fast-forward is safe
#       whoever pushed. jq / git / python3 missing or an invalid payload → exit 1 + JSON.
#
# REVERSIBLE  Remove the PostToolUse Bash matcher entry from claude/settings.json.
set -uo pipefail

# GIT_DIR and friends override -C, and git hooks export them into child processes; unscrubbed,
# every probe below would read whatever repository the parent process was in (AP #31).
# shellcheck source=_lib-repo-identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-repo-identity.sh"
sst3_scrub_git_env

# shellcheck source=_lib-hook-output.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-hook-output.sh"

raw_stdin="$(cat 2>/dev/null || true)"

TAG="SST3 canon-ff"
say() { # <what happened, for the agent> [short line for the operator]
  sst3_hook_emit PostToolUse "$TAG: $1" "$TAG: ${2:-$1}"
}
degraded() { # <why the check could not run>
  printf '%s: %s.\n' "$TAG" "$1" >&2
  say "$1, so the hook could not check whether the shared dotfiles clone needs a fast-forward after this push. Run git -C <the clone> fetch origin, then git -C <the clone> merge --ff-only origin/master if it is on master with no tracked changes." \
    "$1 — fast-forward check skipped."
  exit 1
}
# The payload also carries the tool's whole output, so it is never scanned as text beyond a
# plain substring test: the quote-stripping below runs on the command alone, whose size the
# agent wrote (on a 300KB payload it took 2.4s; on 1.8MB it did not finish in 300s).
if ! command -v jq >/dev/null 2>&1; then
  [[ "$raw_stdin" == *push* ]] && degraded 'jq is not installed'
  exit 0
fi
if ! CMD="$(printf '%s' "$raw_stdin" | jq -r '.tool_input.command // empty' 2>/dev/null)"; then
  [[ "$raw_stdin" == *push* ]] && degraded 'the hook payload is not valid JSON'
  exit 0
fi
[[ -z "$CMD" ]] && exit 0
# Cheap pre-filter: only a command naming push can fire. Taken on the command with quotes and
# backslashes removed (by tr: bash's ${x//…/} is quadratic, 11s on a 300KB command); an ANSI-C
# `$'…'` word always goes on.
plain_cmd="$(printf '%s' "$CMD" | tr -d "'\"\\\\")"
[[ "$plain_cmd" != *push* && "$CMD" != *"\$'"* ]] && exit 0
command -v git >/dev/null 2>&1 || degraded 'git is not installed'
PAYLOAD_CWD="$(printf '%s' "$raw_stdin" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -n "$PAYLOAD_CWD" ]] || PAYLOAD_CWD="$PWD"

# The runtime canon clone (same resolution as sst3-branch-guard.sh canon_clone()).
CANON="${SST3_CANON_CLONE-}"
if [[ -z "$CANON" ]]; then
  CANON="$(readlink -f "$HOME/.claude/commands" 2>/dev/null)" || exit 0
  [[ "$CANON" == */.claude/commands && "$CANON" != "$HOME/.claude/commands" ]] || exit 0
  CANON="${CANON%/.claude/commands}"
fi
CANON_COMMON="$(git -C "$CANON" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[[ -n "$CANON_COMMON" ]] || exit 0

# owner/repo of a remote URL, lower-cased, so https and ssh spellings of one repo compare equal.
repo_id() {
  local u="${1%/}"
  u="${u%.git}"; u="${u//:/\/}"
  local repo="${u##*/}" rest="${u%/*}"
  printf '%s/%s' "${rest##*/}" "$repo" | tr '[:upper:]' '[:lower:]'
}
CANON_ID=""
canon_url="$(git -C "$CANON" config --get remote.origin.url 2>/dev/null)" && CANON_ID="$(repo_id "$canon_url")"

# is_dotfiles <dir> — is <dir> inside a checkout of the canon clone's repository?
is_dotfiles() {
  local common url
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ "$common" == "$CANON_COMMON" ]] && return 0
  url="$(git -C "$1" config --get remote.origin.url 2>/dev/null)" || return 1
  [[ -n "$CANON_ID" && "$(repo_id "$url")" == "$CANON_ID" ]]
}

# Did the command push from a dotfiles checkout? Per git invocation, in the directory it ran in.
lib="$(dirname "${BASH_SOURCE[0]}")/_lib-shellcmd.py"
command -v python3 >/dev/null 2>&1 && [[ -f "$lib" ]] || degraded "the shell-command reader could not run (python3 or $lib is missing)"
fires=""
if ! recs="$(printf '%s' "$CMD" | python3 "$lib" git --cwd "$PAYLOAD_CWD" 2>/dev/null)" \
   || printf '%s\n' "$recs" | jq -e 'select(has("opaque"))' >/dev/null 2>&1; then
  # Unread: decide on the quote-stripped text. A push that cannot be placed is checked anyway.
  [[ "$plain_cmd" =~ (^|[^[:alnum:]_-])git([[:space:]]+[^[:space:]]+)*[[:space:]]+push([^[:alnum:]_-]|$) ]] && fires="unknown"
else
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    if [[ "$d" == "-" ]]; then fires="unknown"; break; fi
    if is_dotfiles "$d"; then fires="dotfiles"; break; fi
  done < <(printf '%s\n' "$recs" | jq -r 'select(.tool == "git" and .verb == "push")
                                          | (.git_dir // .cwd) // "-"' 2>/dev/null)
fi
[[ -n "$fires" ]] || exit 0
if [[ "$fires" == dotfiles ]]; then
  PUSH="a push from a dotfiles checkout ran"
else
  PUSH="a push ran whose repository the hook could not tell (checked anyway: the fast-forward is safe whoever pushed)"
fi

# Fast-forward the canon clone, or say why not. coreutils timeout bounds a hung fetch where
# it exists (macOS ships without it).
tmo=()
command -v timeout >/dev/null 2>&1 && tmo=(timeout 30)
if ! out="$(${tmo[@]+"${tmo[@]}"} git -C "$CANON" fetch -q origin 2>&1)"; then
  say "$PUSH, but git fetch origin failed in the shared clone $CANON (${out:-no output}), so it was not fast-forwarded. Consumer drift and SEC hooks refuse while it is behind; tell the operator." \
    "fetch failed in $CANON; not fast-forwarded."
  exit 0
fi
default="$(git -C "$CANON" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)"
default="${default#origin/}"
[[ -n "$default" ]] || default="master"
if ! git -C "$CANON" rev-parse --verify -q "refs/remotes/origin/$default^{commit}" >/dev/null 2>&1; then
  say "$PUSH, but origin/$default does not resolve in the shared clone $CANON, so it was not fast-forwarded. Tell the operator." \
    "origin/$default unresolvable in $CANON; not fast-forwarded."
  exit 0
fi
branch="$(git -C "$CANON" symbolic-ref --short -q HEAD 2>/dev/null)"
if [[ "$branch" != "$default" ]]; then
  say "$PUSH, but the shared clone $CANON is on ${branch:-a detached HEAD}, not $default, so it was not fast-forwarded. Ruling 11: the operator, or the session that moved it, returns it to $default; tell the operator. Consumer drift and SEC hooks refuse until it is back on $default." \
    "$CANON is on ${branch:-a detached HEAD}, not $default; not fast-forwarded."
  exit 0
fi
git -C "$CANON" diff --quiet HEAD -- 2>/dev/null; rc=$?
if (( rc != 0 )); then
  if (( rc == 1 )); then why="has uncommitted tracked changes"; else why="could not be diffed (git diff rc=$rc)"; fi
  say "$PUSH, but the shared clone $CANON $why, so it was not fast-forwarded. They belong to someone else: leave them and tell the operator." \
    "$CANON $why; not fast-forwarded."
  exit 0
fi
behind="$(git -C "$CANON" rev-list --count "HEAD..origin/$default" 2>/dev/null)"
ahead="$(git -C "$CANON" rev-list --count "origin/$default..HEAD" 2>/dev/null)"
[[ "$behind" =~ ^[0-9]+$ && "$ahead" =~ ^[0-9]+$ ]] || degraded "git could not count commits between HEAD and origin/$default in $CANON"
# Ahead is named even when level: consumer gates refuse a canon clone that is ahead too.
if (( ahead > 0 )); then
  say "$PUSH, but the shared clone $CANON has $ahead commit(s) that origin/$default lacks, so it cannot be fast-forwarded and consumer drift and SEC hooks refuse it. Tell the operator." \
    "$CANON is $ahead ahead of origin/$default; not fast-forwarded."
  exit 0
fi
(( behind == 0 )) && exit 0
before="$(git -C "$CANON" rev-parse --short HEAD 2>/dev/null)"
if out="$(git -C "$CANON" merge --ff-only -q "origin/$default" 2>&1)"; then
  after="$(git -C "$CANON" rev-parse --short HEAD 2>/dev/null)"
  say "fast-forwarded the shared clone $CANON from $before to $after ($behind commit(s), origin/$default): $PUSH, and the operator ruled the clone is caught up after a dotfiles push (#577). Consumer hooks now read the current canon." \
    "fast-forwarded $CANON $before..$after ($behind commit(s))."
else
  say "$PUSH, but git merge --ff-only origin/$default refused in the shared clone $CANON: ${out:-no output}. Nothing was changed; tell the operator." \
    "ff-only refused in $CANON; not fast-forwarded."
fi
exit 0
