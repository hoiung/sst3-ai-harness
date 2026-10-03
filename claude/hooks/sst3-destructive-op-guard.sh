#!/usr/bin/env bash
# sst3-destructive-op-guard.sh — F-4 destructive-op PreToolUse hook (#498 AC 2.7).
#
# WHAT  Claude Code PreToolUse Bash matcher. Classifies the command into:
#         ALLOW    silent pass (allowlist match — paper/live/DS systemctl
#                  restart, the operator's pre-authorised cadence)
#         WARN     exit 0 + additionalContext for the agent (dotfiles#577 AC 1.2 —
#                  exit-0 stderr is debug-log only) — --no-verify / SKIP=…
#                  preserved as visible-by-design observability
#         DENY     exit 2 (blocks tool call) for irreversible destructive ops:
#                    git push --force / --force-with-lease
#                    git filter-repo
#                    git reset --hard
#                    git branch force-delete (-D, or a delete flag with a force flag
#                      in any spelling) unless the branch is confirmed merged (below)
#                    rm -rf /<absolute path>
#                    DROP TABLE (in any embedded SQL)
#
# WHY   Operator-authorised paper/live/DS restarts are routine; force-pushes
#       and history-rewrites are irreversible. The branch-guard already gates
#       the dotfiles#488 class; this guards the Issue #1448-class + dotfiles#497
#       (filter-repo) class. ESCAPE HATCH: SST3_DESTRUCTIVE_OVERRIDE=1 bypasses
#       DENY (matches branch-guard precedent). It is read from THIS hook's process
#       environment, which Claude Code hands down from the shell that launched it:
#       the operator exports it there and restarts Claude Code. A `VAR=1 cmd` prefix
#       on the Bash command never reaches the hook, so the DENY text must not tell
#       the agent to "set" it (dotfiles#577 AC 1.3).
#
# ALLOWLIST  The restart allowlist matches the WHOLE command. It used to match anywhere in
#       it, and ALLOW exits before any DENY check, so a force-push chained behind a restart
#       (`<restart> && <force-push>`) was allowed (measured, dotfiles#577 AC 1.4).
#
# DATA IS NOT A COMMAND (dotfiles#577 AC 1.4a)  A heredoc BODY is left out of the
#       classification only when the whole command is ONE data-sink statement: `cat` or
#       `tee` writing to a plain FILE, with a QUOTED delimiter (single-quoted, double-quoted
#       or backslash-escaped — an unquoted body still expands $(…) and backticks), no ; && ||
#       | $( or backtick on the statement line, and nothing after the terminator line.
#       Anything else — a heredoc fed to an interpreter directly, through a pipe or a process
#       substitution, or a file written and then run by a later statement — is classified
#       whole, body included. (A live false DENY, 2026-09-25: a `cat >> file` heredoc append
#       whose prose named the branch-delete command.) No heredoc SYNTAX is written out in this
#       file: test_hook_git_env_scrub.sh tokenises it and refuses any file that carries one.
#
# MERGED-BRANCH DELETE (dotfiles#577 AC 1.4c)  A branch force-delete is allowed only when
#       the command is exactly one plain `git branch <delete+force flags> <one name>` and
#       `git merge-base --is-ancestor refs/heads/<name> <default>` passes in the repo named by
#       the payload `.cwd`, <default> being `git symbolic-ref refs/remotes/origin/HEAD`. The
#       fully-qualified refs/heads/ keeps a same-named TAG from answering for the branch. A
#       git option before `branch` (-C, --git-dir, --work-tree …), a prefix, a cd, a second
#       statement, several names, an unknown option, an unresolvable default or a failed
#       check stays DENY. GIT_* is scrubbed first (_lib-repo-identity.sh, AP #31): an
#       inherited GIT_DIR would otherwise answer for the parent process's repository.
#
# CONTRACT  stdin = PreToolUse JSON; `.tool_input.command` read via jq (and `.cwd`, only
#       when a branch force-delete is seen). Fail-toward-FLAG (AC2-equivalent): jq missing →
#       exit 1 + JSON (operator systemMessage + agent additionalContext; advisory, does NOT
#       block).
#
# AUDIT (AP #12)  One line per decision: allow (allowlist), allow-merged-branch,
#       sink-excluded (the heredoc statement line only, not its body), warn, deny.
#
# REVERSIBLE  Remove the PreToolUse Bash matcher entry from claude/settings.json
#       or set `"disableAllHooks": true`.
set -uo pipefail

OVERRIDE="${SST3_DESTRUCTIVE_OVERRIDE:-0}"
LOG="${SST3_DESTRUCTIVE_LOG:-$HOME/.claude/hooks/destructive-op-guard.log}"
# Log rotation cap (#498 Stage 5 L1C F6). Default 5MB — when exceeded, the log
# is truncated to its tail (last LOG_TAIL_BYTES bytes) so growth is bounded
# without losing recent audit history. Override via SST3_DESTRUCTIVE_LOG_MAX_BYTES.
LOG_MAX_BYTES="${SST3_DESTRUCTIVE_LOG_MAX_BYTES:-5242880}"
LOG_TAIL_BYTES="${SST3_DESTRUCTIVE_LOG_TAIL_BYTES:-2621440}"

# shellcheck source=_lib-hook-output.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-hook-output.sh"
# shellcheck source=_lib-repo-identity.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-repo-identity.sh"
# Before any git probe (AP #31): the merged-branch check must read the payload cwd's repo.
sst3_scrub_git_env

audit() {
  local decision="$1" cmd="$2" rec
  # Rotate (truncate-to-tail) when over cap. stat -c is GNU; fall back to wc -c
  # for portability (BSD stat). Failure to rotate is non-fatal — append still happens.
  if [[ -f "$LOG" ]]; then
    local sz
    sz="$(stat -c %s "$LOG" 2>/dev/null || wc -c <"$LOG" 2>/dev/null || printf 0)"
    if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > LOG_MAX_BYTES )); then
      local tmp="${LOG}.rotating"
      if tail -c "$LOG_TAIL_BYTES" "$LOG" >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$LOG" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
      else
        rm -f "$tmp" 2>/dev/null || true
      fi
    fi
  fi
  printf -v rec 'ts=%s cwd=%s decision=%s cmd=%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" "$decision" "$cmd"
  sst3_audit_append "$LOG" "$rec" destructive-op-guard || :
}

emit_warn() {
  # WARN advisory: command STILL runs. The agent reads additionalContext; the stderr
  # line is for the debug log only.
  printf 'F-4 destructive-op-guard: %s — advisory only, command will proceed.\n' "$1" >&2
  audit warn "$2"
  sst3_hook_emit PreToolUse "F-4 destructive-op-guard: $1. The command was allowed and has run. If the operator did not sanction this bypass, say so in the Issue and re-run without it."
  exit 0
}
emit_deny() {
  printf 'F-4 destructive-op-guard: BLOCKED — %s\n' "$1" >&2
  printf '  Only the operator can release this. Ask them to run the command in their own terminal, or to export SST3_DESTRUCTIVE_OVERRIDE=1 in the shell that launches Claude Code and then restart Claude Code. A variable given on the command you run here never reaches this hook.\n' >&2
  audit deny "$2"
  exit 2
}
emit_allow() {
  audit allow "$1"
  exit 0
}

# ---------------------------------------------------------------- heredoc data sink --------
# is_sink_stmt <statement line, heredoc operator removed> — true when it only writes to a
# plain file: `cat >FILE`, `cat >>FILE`, or `tee [-a|--append] FILE [>/dev/null]`.
SINK_FILE='[A-Za-z0-9_./~+-]+'
SINK_RE="^[[:space:]]*(cat[[:space:]]*>>?[[:space:]]*${SINK_FILE}|tee[[:space:]]+(-a[[:space:]]+|--append[[:space:]]+)?${SINK_FILE}([[:space:]]*>[[:space:]]*/dev/null)?)[[:space:]]*$"
is_sink_stmt() {
  # shellcheck disable=SC2016  # '$(' is the literal command-substitution opener being REJECTED, not an expansion.
  case "$1" in *';'*|*'&&'*|*'||'*|*'|'*|*'$('*|*'`'*) return 1 ;; esac
  [[ "$1" =~ $SINK_RE ]]
}

# heredoc_sink_head <command> — when the WHOLE command is one data-sink heredoc statement,
# set SINK_HEAD to its statement line (the only part left to classify) and return 0.
HEREDOC_OP_RE="<<(-?)[[:space:]]*(['\"\\\\]?)([A-Za-z_][A-Za-z0-9_]*)(['\"]?)"
SINK_HEAD=""
heredoc_sink_head() {
  local c="$1" first rest open dash q1 delim q2 line found=0
  [[ "$c" == *$'\n'* ]] || return 1
  first="${c%%$'\n'*}"; rest="${c#*$'\n'}"
  [[ "$first" =~ $HEREDOC_OP_RE ]] || return 1
  open="${BASH_REMATCH[0]}"; dash="${BASH_REMATCH[1]}"; q1="${BASH_REMATCH[2]}"
  delim="${BASH_REMATCH[3]}"; q2="${BASH_REMATCH[4]}"
  # QUOTED delimiter only: an unquoted body still expands $(…) and backticks.
  # shellcheck disable=SC1003  # '\' is the literal backslash of the backslash-escaped delimiter form.
  [[ -n "$q1" && ( ( "$q1" == '\' && -z "$q2" ) || "$q1" == "$q2" ) ]] || return 1
  # SINK_RE leaves no room for a second redirection, so a second heredoc also fails here.
  is_sink_stmt "${first/"$open"/ }" || return 1
  # The body runs to the first line that is exactly the delimiter (leading tabs allowed with
  # <<-). Anything after that terminator is a second statement: classify the whole command.
  while IFS= read -r line; do
    if (( found )); then
      [[ "$line" =~ ^[[:space:]]*$ ]] || return 1
      continue
    fi
    [[ -n "$dash" ]] && line="${line#"${line%%[!$'\t']*}"}"
    [[ "$line" == "$delim" ]] && found=1
  done <<< "$rest"
  (( found )) || return 1
  SINK_HEAD="$first"
}

# ---------------------------------------------------------------- merged branch delete -----
# Detection is deliberately broad (a git option before `branch`, -D alone or in a cluster, a
# delete flag with a force flag in either order or one cluster); the ALLOW below is narrow.
# The flags are looked for within the `git branch` statement only (up to ; & | or a newline),
# so `git branch …; git clean -fd` is not a force-delete. It runs on BR_SUBJECT, which joins
# backslash-continued lines first, so a continuation cannot hide the flag on the next line.
_bf_ns=$'[^;&|\n]'
_bf_git="(^|[^[:alnum:]_-])git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+branch[[:space:]](${_bf_ns}*[[:space:]])?"
_bf_del='(--delete|-[[:alpha:]]*d[[:alpha:]]*)'
_bf_frc='(--force|-[[:alpha:]]*f[[:alpha:]]*)'
_bf_gap="[[:space:]](${_bf_ns}*[[:space:]])?"
BRANCH_FD_RE="${_bf_git}(-[[:alpha:]]*D[[:alpha:]]*|-[[:alpha:]]*(d[[:alpha:]]*f|f[[:alpha:]]*d)[[:alpha:]]*|${_bf_del}${_bf_gap}${_bf_frc}|${_bf_frc}${_bf_gap}${_bf_del})([^[:alnum:]_-]|$)"
BR_SINGLE_RE='^[[:space:]]*git[[:blank:]]+branch([[:blank:]]+[A-Za-z0-9._/+-]+)+[[:space:]]*$'

# merged_branch_delete — BR_REASON stays empty only when BR_SUBJECT (the classified text with
# backslash-continued lines joined, as the shell joins them) is ONE plain `git branch`
# force-delete of ONE branch merged into origin's default branch in the payload cwd's repo.
BR_REASON=""
merged_branch_delete() {
  local -a tok names=()
  local a c cwd def name rc
  BR_REASON=""
  if [[ ! "$BR_SUBJECT" =~ $BR_SINGLE_RE ]]; then
    BR_REASON="not one plain 'git branch' statement (a git option such as -C / --git-dir / --work-tree, a prefix, a cd, a second statement or quoting) — only the payload cwd's repo is checked"
    return
  fi
  read -r -a tok <<< "$BR_SUBJECT"
  for a in "${tok[@]:2}"; do
    case "$a" in
      --delete|--force) ;;
      -*) c="${a#-}"
          [[ "$c" =~ ^[dDf]+$ ]] || { BR_REASON="unrecognised option $a"; return; } ;;
      *) names+=("$a") ;;
    esac
  done
  if (( ${#names[@]} != 1 )); then
    BR_REASON="${#names[@]} branch names — one name is checked, not several"
    return
  fi
  name="${names[0]}"
  cwd="$(printf '%s' "$raw_stdin" | jq -r '.cwd // empty' 2>/dev/null)"
  if [[ -z "$cwd" || ! -d "$cwd" ]]; then
    BR_REASON="the payload carries no usable cwd"
    return
  fi
  if ! command -v git >/dev/null 2>&1; then
    BR_REASON="git is not available to check the merge state"
    return
  fi
  if ! def="$(git -C "$cwd" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || [[ -z "$def" ]]; then
    BR_REASON="origin's default branch is unresolvable in $cwd (no refs/remotes/origin/HEAD)"
    return
  fi
  if ! git -C "$cwd" rev-parse --verify --quiet "refs/heads/$name^{commit}" >/dev/null 2>&1; then
    BR_REASON="$cwd has no local branch $name"
    return
  fi
  git -C "$cwd" merge-base --is-ancestor "refs/heads/$name" "$def" 2>/dev/null; rc=$?
  case "$rc" in
    0) ;;
    1) BR_REASON="refs/heads/$name is not merged into $def in $cwd" ;;
    *) BR_REASON="the merge check failed in $cwd (git merge-base exit $rc)" ;;
  esac
}

raw_stdin="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf 'F-4 destructive-op-guard: jq missing; command NOT inspected.\n' >&2
  sst3_hook_emit PreToolUse \
    'F-4 destructive-op-guard: jq is not installed, so the command you just ran was NOT checked for destructive operations (force-push, filter-repo, reset --hard, branch -D, rm -rf /, DROP TABLE). Until jq is back, check each such command yourself before running it.' \
    'F-4 destructive-op-guard: jq missing — destructive-op checks are OFF. Install jq (apt install jq; scripts/provision.sh installs it from wsl/packages.txt).'
  exit 1
fi

# #577 escalation (class C3, fail-open reader): a payload jq cannot parse gave an
# empty CMD below, which exits 0 as "no command" — a command the guard never
# read. It is the jq-missing case: not inspected, and said so.
if ! printf '%s' "$raw_stdin" | jq empty 2>/dev/null; then
  printf 'F-4 destructive-op-guard: hook payload is not valid JSON; command NOT inspected.\n' >&2
  sst3_hook_emit PreToolUse \
    'F-4 destructive-op-guard: the hook payload was not valid JSON, so the command you just ran was NOT checked for destructive operations (force-push, filter-repo, reset --hard, branch -D, rm -rf /, DROP TABLE). Check that command yourself before relying on it.' \
    'F-4 destructive-op-guard: hook payload unparseable — this command was NOT checked for destructive operations.'
  exit 1
fi

CMD="$(printf '%s' "$raw_stdin" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$CMD" ]] && exit 0   # Non-Bash tool / no command field — nothing to classify.

# Allowlist — explicit, exact-form: paper/live/DS systemctl restarts, the WHOLE command.
if [[ "$CMD" =~ ^[[:space:]]*sudo[[:space:]]+systemctl[[:space:]]+restart[[:space:]]+pb-(paper-controller|live-controller|data-service-rs[0-9a-z-]*)[[:space:]]*$ ]]; then
  emit_allow "$CMD"
fi

# What is classified: the whole command, or only the statement line of a data-sink heredoc.
CLASSIFY="$CMD"
if heredoc_sink_head "$CMD"; then
  CLASSIFY="$SINK_HEAD"
  audit sink-excluded "$SINK_HEAD"
fi

# DENY class — irreversible. Checked BEFORE WARN so a force-push with
# --no-verify (which would also WARN) still DENY-blocks.
if [[ "$OVERRIDE" != "1" ]]; then
  # git push --force / --force-with-lease / -f / refspec `+ref:ref`.
  # `-f` is git's documented short form for --force (`man git-push`); refspec `+`
  # is the documented force-update syntax (`git-push(1)` §<refspec>). Both bypass
  # the long-form DENY if not explicitly matched. Pattern requires `git push`
  # then optional `<args> ` (one or more space-terminated args), then one of the
  # 4 force forms. `-f` boundary uses `[^[:alnum:]_-]|$` AFTER to avoid matching
  # `-fast` or `-foo`; preceded by `[[:space:]]+` after `push` to anchor it as
  # a standalone arg (not a substring of `--force`).
  if [[ "$CLASSIFY" =~ (^|[^[:alnum:]_-])git[[:space:]]+push[[:space:]]+(.*[[:space:]])?(--force([^-]|$)|--force-with-lease|-f([^[:alnum:]_-]|$)|\+[A-Za-z0-9_/.+-]+:[A-Za-z0-9_/.+-]+) ]]; then
    emit_deny "git push --force / -f / --force-with-lease / refspec + (irreversible)" "$CMD"
  fi
  # git filter-repo (history rewrite — dotfiles#497 class).
  if [[ "$CLASSIFY" =~ (^|[^[:alnum:]_-])git[[:space:]]+filter-repo([^[:alnum:]_-]|$) ]]; then
    emit_deny "git filter-repo (history rewrite, irreversible to public mirrors)" "$CMD"
  fi
  # git reset --hard.
  if [[ "$CLASSIFY" =~ (^|[^[:alnum:]_-])git[[:space:]]+reset[[:space:]].*--hard([^[:alnum:]_-]|$) ]]; then
    emit_deny "git reset --hard (uncommitted-work loss)" "$CMD"
  fi
  # git branch force-delete — allowed only for one branch confirmed merged (header).
  BR_SUBJECT="${CLASSIFY//$'\\\n'/ }"
  if [[ "$BR_SUBJECT" =~ $BRANCH_FD_RE ]]; then
    merged_branch_delete
    [[ -n "$BR_REASON" ]] && emit_deny "git branch force-delete not confirmed merged: $BR_REASON" "$CMD"
    audit allow-merged-branch "$CMD"
  fi
  # rm -rf / — root or absolute-path bombing pattern.
  if [[ "$CLASSIFY" =~ (^|[^[:alnum:]_-])rm[[:space:]]+(-[A-Za-z]*[rR][A-Za-z]*[fF][A-Za-z]*|-[A-Za-z]*[fF][A-Za-z]*[rR][A-Za-z]*)([[:space:]].+)?[[:space:]]+/($|[^.]) ]]; then
    emit_deny "rm -rf / (filesystem destruction)" "$CMD"
  fi
  # DROP TABLE (SQL embedded in shell args or scripts).
  if [[ "$CLASSIFY" =~ (DROP|drop)[[:space:]]+(TABLE|table)([[:space:]]|;|$) ]]; then
    emit_deny "DROP TABLE (SQL destructive)" "$CMD"
  fi
fi

# WARN class — advisory; command runs.
if [[ "$CLASSIFY" =~ --no-verify([^[:alnum:]_-]|$) ]]; then
  emit_warn "--no-verify bypasses pre-commit hooks (audit-trail visible-by-design)" "$CMD"
fi
if [[ "$CLASSIFY" =~ (^|[^[:alnum:]_-])SKIP=[A-Za-z0-9_,-]+[[:space:]] ]]; then
  emit_warn "SKIP=<hook> bypasses one or more pre-commit hooks" "$CMD"
fi

exit 0
