#!/usr/bin/env bash
# sst3-branch-guard.sh — SST3 PreToolUse branch-safety runtime guard (dotfiles#490)
#
# WHAT  A Claude Code PreToolUse hook (matcher "Bash"). Intercepts a Bash git
#       branch *switch to an existing branch* or *non-solo/* branch create*
#       BEFORE it executes and surfaces the SST3 branch-safety rule.
#
# WHY   CLAUDE.md "Branch Safety (CRITICAL — DO NOT VIOLATE)" / "NEVER switch
#       branches" is the dotfiles#488 worktree-isolation invariant but is
#       prose-only with no runtime backstop: a branch switch produces no
#       commit, so the git pre-commit hooks (which fire at commit time) cannot
#       intercept it — HEAD has already moved and muddled a concurrent
#       worktree. STANDARDS.md:30 makes "Enforcement … not honor system" a
#       core principle. This hook is that runtime backstop.
#
# MODE  (AC4 — no hardcode) env var SST3_BRANCH_GUARD_MODE:
#         WARN  default, shipped — exit 0 + systemMessage (operator) AND
#               hookSpecificOutput.additionalContext (agent — dotfiles#577 AC 1.2;
#               the systemMessage alone never reached the agent); command STILL
#               RUNS (advisory; surfaces false positives before it can block).
#         DENY  operator-gated flip — exit 2 + stderr; command BLOCKED.
#       An exit-2 PreToolUse hook stops the tool call BEFORE permission rules
#       are evaluated, so DENY overrides the `permissions.allow`
#       `Bash(git checkout:*)` entry in claude/settings.local.json. Verbatim,
#       code.claude.com/docs/en/permissions (each quote kept on ONE line so it
#       greps as a single literal — cross-checked against AC10's research-doc
#       correction which carries the same verbatim text):
#         "A hook that exits with code 2 stops the tool call before permission rules are evaluated, so the block applies even when an allow rule would otherwise let the call proceed."
#         "When Claude Code makes a tool call, PreToolUse hooks run before the permission prompt"
#       And the Auto-Mode ordering, code.claude.com/docs/en/auto-mode-config:
#         "The classifier is a second gate that runs after the permissions system."
#       Chain: exit-2 PreToolUse hook → permission rules → Auto-Mode classifier.
#       DENY is strictly upstream of both; no reordering risk.
#
# REVERSIBLE (AC9)  Remove the `hooks` block from claude/settings.json, or set
#       `"disableAllHooks": true` in settings — zero residual state. The only
#       on-disk artefact is the append-only audit log below, inert when
#       unwired (no process reads it; it is a passive record).
#
# CANON LOCK (dotfiles#577 D1, operator ruling 11)  The clone that
#       ~/.claude/commands links into is the RUNTIME CANON: commands, agents,
#       skills, the checkbox MCP and every consumer `../dotfiles` hook read its
#       working tree. A branch switch or create there silently swaps the canon
#       every session runs (measured 2026-10-04: it sat 372 commits behind on
#       another session's branch, so #577 was live only in the copied hooks).
#       Inside that clone ANY branch switch/create — solo creates included —
#       is DENIED (exit 2) whatever SST3_BRANCH_GUARD_MODE says; the one
#       allowed move is a plain `git checkout|switch <default-branch>`, the
#       recovery. The target directory is the event's `.cwd`, updated by
#       `cd`/`pushd` segments and `git -C`/`--work-tree`/`--git-dir`/GIT_DIR.
#       SST3_CANON_CLONE overrides the clone path (tests); with no symlinked
#       ~/.claude/commands there is no runtime canon to lock.
#
# AUDIT (AC5 / AP #12 — observability at write time)  Every fire (WARN or
#       DENY) appends one structured line to ~/.claude/hooks/branch-guard.log
#       (override path via SST3_BRANCH_GUARD_LOG). This makes the operator's
#       WARN→DENY activation gate *measurable*: flip after a recorded
#       clean-observation window.
#
# CONTRACT  stdin = PreToolUse JSON; `.tool_input.command` read via jq.
#       Parse-failure stance (AC2, fail-toward-FLAG): jq missing, or a branch
#       verb present but wrapped so the classifier cannot clear it
#       confidently (eval "…" / bash -c '…' / $(…) / here-string) → treated
#       as FLAGGED, never silently SAFE. Mirrors the official hooks-doc
#       fail-safe and AC2's jq-missing fail-CLOSED logic.
#
# THREAT MODEL + KNOWN BOUNDARY  This backstops the SST3 agent's *accidental*
#       HEAD moves (CLAUDE.md:50 — the dotfiles#488 harm), not a hostile actor
#       defeating its own guardrail. It is a deterministic classifier, NOT a
#       shell interpreter (operator scope: "narrow first"). It handles literal
#       commands, prefixes (grouping / `!` / redirection / exec-wrappers /
#       generic backslash quote-removal / line-continuation / empty-quote-glue
#       / ANY git global option before the verb — structural, not enumerated),
#       single-indirection (`$GIT checkout`, `git $c`), and git
#       inline-alias-to-verb (incl. whitespace around `=`).
#       EXPLICIT documented boundary (like the adjacent-destructive class in
#       the Issue §Context — a stated limit, NOT a silent gap): full
#       cross-statement variable resolution where BOTH the command and the
#       subcommand are indirected through separately-assigned vars with no
#       literal `git`/`checkout` token anywhere (`a=git;b=checkout; $a $b x`)
#       is out of scope — resolving it requires a shell interpreter. That form
#       is deliberate obfuscation, not the accidental-drift threat; WARN-first
#       + the AC5 audit log + operator-gated DENY are the compensating control.
set -uo pipefail

MODE="${SST3_BRANCH_GUARD_MODE:-WARN}"
LOG="${SST3_BRANCH_GUARD_LOG:-$HOME/.claude/hooks/branch-guard.log}"

# WARN_MSG is the operator's systemMessage; WARN_CTX is the agent's additionalContext
# and carries no SST3_* mode hint (an agent cannot set a hook's environment — AC 1.3).
# Both are JSON-escaped by _lib-hook-output.sh, which needs no jq.
WARN_MSG='SST3 branch-safety: this git command moves/clobbers HEAD in the shared or worktree clone — the dotfiles#488 isolation hazard. Use the EnterWorktree tool (see CLAUDE.md Branch Safety section). WARN mode: the command STILL RAN; set SST3_BRANCH_GUARD_MODE=DENY to block.'
WARN_CTX='SST3 branch-safety: the git command you just ran moves or clobbers HEAD in a shared or worktree clone (the dotfiles#488 isolation hazard); it was allowed and has run. Never switch branches: check that this worktree is still on its solo branch (git branch --show-current) and move work into an isolated worktree with the EnterWorktree tool (CLAUDE.md Branch Safety section).'
DENY_MSG='SST3 branch-safety: branch switch/clobber BLOCKED (dotfiles#488 worktree-isolation invariant). Use the EnterWorktree tool; see CLAUDE.md Branch Safety section. (SST3_BRANCH_GUARD_MODE=DENY)'

# shellcheck source=_lib-hook-output.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib-hook-output.sh"

audit() {
  # AC5: ts=<iso> cwd=<dir> cmd=<matched> mode=<WARN|DENY> decision=<warn|deny>
  local decision="$1" cmd="$2" rec
  printf -v rec 'ts=%s cwd=%s cmd=%s mode=%s decision=%s' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" "$cmd" "$MODE" "$decision"
  sst3_audit_append "$LOG" "$rec" branch-guard || :
}

# Decision sink. WARN → advisory (command runs); DENY → block (exit 2).
flag() {
  local cmd="$1"
  if [[ "$MODE" == "DENY" ]]; then
    audit deny "$cmd"
    printf '%s\n' "$DENY_MSG" >&2
    exit 2
  fi
  audit warn "$cmd"
  sst3_hook_emit PreToolUse "$WARN_CTX" "$WARN_MSG"
  exit 0
}
safe() { exit 0; }

raw_stdin="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  # AC2: jq missing — WARN degraded-advisory (fail-open), DENY fail-CLOSED.
  if [[ "$MODE" == "DENY" ]]; then
    printf 'SST3 branch-safety: jq not found — fail-CLOSED in DENY mode (cannot verify command safety). Install jq (apt install jq; scripts/provision.sh installs it from wsl/packages.txt) or use WARN.\n' >&2
    exit 2
  fi
  sst3_hook_emit PreToolUse \
    'SST3 branch-safety: jq is not installed, so the branch guard could not inspect the command you just ran. If it switched or created a branch, check that this worktree is still on its solo branch (CLAUDE.md Branch Safety section).' \
    'SST3 branch-safety: jq not found — classifier degraded, command not inspected. Verify branch safety manually (CLAUDE.md Branch Safety section). Install jq: apt install jq (scripts/provision.sh installs it from wsl/packages.txt).'
  exit 0
fi

CMD="$(printf '%s' "$raw_stdin" | jq -r '.tool_input.command // empty' 2>/dev/null)"; jqrc=$?
# AC2 fail-toward-FLAG — JSON-envelope axis (Stage-5): jq is present but the
# PreToolUse JSON itself did not parse (jq rc≠0) on non-empty input → that is
# "unparseable input", and AC2's literal stance is *never silently SAFE*.
# Production Claude Code always emits well-formed PreToolUse JSON, so this
# never fires under the real contract — pure robustness/fidelity, zero
# behavioural change in normal operation. A *valid* JSON event with no
# `.tool_input.command` (EnterWorktree / non-Bash tool surface) parses fine
# (jq rc=0, CMD empty) and still SAFEs on the next line — unaffected.
if [[ $jqrc -ne 0 && -n "${raw_stdin//[[:space:]]/}" ]]; then
  flag "$(printf '%.200s' "$raw_stdin" | tr '\n' ' ')"
fi
[[ -z "$CMD" ]] && safe   # valid JSON, no command field (non-Bash / EnterWorktree) — nothing to classify
RAW_CMD="$CMD"           # as typed: the canon pass reads it with the shared shell reader

# Pre-tokenisation shell-normalisation (Ralph Tier-3 #4 + Stage-5 Class-A FN).
# The shell collapses these BEFORE exec, so the classifier MUST too, else a
# real `git checkout` silently SAFEs (verified HEAD-mover). Done BEFORE the
# quick-exit so `git check""out` / `git che\ckout` (no literal `checkout`
# substring yet) is not wrongly short-circuited:
#  - backslash-newline line-continuation removed FIRST (idiomatic wrapped
#    command — `git \⏎checkout feature` → `git checkout feature`; the `\` AND
#    the newline both go, joining the lines)
#  - empty-quote glue removed (`g""it`→`git`, `git check''out`→`git checkout`)
#  - generic backslash quote-removal LAST (Stage-5 Class-A fix): the shell
#    strips an unquoted `\` before exec (`git che\ckout other` runs
#    `git checkout other`, a verified HEAD-mover). The earlier code only
#    de-escaped the *git command word* (`\git`/`g\it`) and missed the *verb*
#    (`che\ckout`/`\checkout`/`sw\itch`), which then dodged the quick-exit
#    below. Stripping every `\` here can only make a hidden verb visible (it
#    never hides one — a removed `\` only merges chars); a non-git command
#    that incidentally forms `checkout` still needs a whole-word `git` lead or
#    `$`-lead to FLAG (so `echo che\ckout` stays SAFE), and `git commit -m
#    "a\nb"` resolves verb=commit → SKIP. This subsumes the old git-word-only
#    de-escape (now removed from the segment unwrap loop).
CMD="${CMD//\\$'\n'/}"
CMD="${CMD//\"\"/}"
CMD="${CMD//\'\'/}"
CMD="${CMD//\\/}"

# Quick exit: no branch verb anywhere → cannot be a switch/create. (A worktree
# path literally containing "checkout" does NOT quick-exit; it is verb-anchored
# SAFE in the segment walk below.) `git symbolic-ref HEAD refs/heads/x` and gh's
# `gh co` alias move HEAD too, and an ANSI-C `$'…'` word can spell any verb, so each
# goes on to the canon pass (#577 Stage 5 fix review 2).
if [[ "$CMD" != *checkout* && "$CMD" != *switch* && "$CMD" != *bisect* && "$CMD" != *symbolic-ref* \
      && ! "$CMD" =~ (^|[^[:alnum:]_.-])gh[[:space:]] && "$RAW_CMD" != *"\$'"* ]]; then
  safe
fi

# dotfiles#495 AC 5.1: is_solo() also recognises the EnterWorktree-renamed
# `worktree-solo+issue-N-*` form.
#   (a) EnterWorktree applies a `/` → `+` rename when materialising the on-disk
#       worktree branch (an isolated `solo/issue-N-foo` becomes
#       `worktree-solo+issue-N-foo` on the actual branch ref).
#   (b) This guard fires PreToolUse on git Bash commands, so it observes the
#       POST-rename branch name — EnterWorktree invokes git internally and the
#       hook sees the final form, not an intermediate pre-rename literal.
#   (c) Both forms are operationally valid solo branches (Gate-2 server-FF push
#       handles both via the same `git push origin <branch>:master` pattern).
# Same class of bug + same fix as check-phase-ac-cadence.py BRANCH_RE
# extension (commit 9c6d5d0) — Phase 4 bonus finding generalised here.
# #509 AC6.5: solo-branch forms aligned with the canonical sst3_utils.SOLO_BRANCH_RE
# (Python) + sst3_solo_branch_alt (bash util). This hook is INSTALLED standalone to
# ~/.claude/hooks/ so it cannot source the repo helper at runtime; the glob is the
# aligned literal — solo/* plus both EnterWorktree-rename forms (+ and legacy -). KEEP IN SYNC.
is_solo()      { [[ "$1" == solo/* || "$1" == worktree-solo+issue-* || "$1" == worktree-solo-issue-* ]]; }
is_sha()       { [[ "$1" =~ ^[0-9a-fA-F]{7,40}$ ]]; }
is_prevref()   { [[ "$1" == "-" || "$1" =~ ^@\{-[0-9]+\}$ ]]; } # git checkout - / @{-N}
is_headref()   { [[ "$1" =~ ^HEAD([~^][0-9]*)+$ || "$1" =~ ^HEAD@\{ ]]; }
has_fileext()  { [[ "$1" =~ \.[A-Za-z0-9_]+$ ]]; }

# Classify the args of `git checkout …` (verb already consumed). Echoes FLAG|SAFE.
classify_checkout() {
  local -a a=("$@") i tok
  for ((i = 0; i < ${#a[@]}; i++)); do
    tok="${a[i]}"
    if [[ "$tok" == "-b" || "$tok" == "-B" ]]; then
      local branch="${a[i + 1]-}"
      if [[ -n "$branch" ]] && is_solo "$branch"; then echo SAFE_CREATE; else echo FLAG; fi
      return
    fi
    [[ "$tok" == "--detach" ]] && { echo FLAG; return; }        # detached HEAD
  done
  # Locate the first operand, skipping option flags. `-` (prev branch) and `--`
  # (pathspec separator) are operands, not skippable flags.
  local first=""
  for ((i = 0; i < ${#a[@]}; i++)); do
    tok="${a[i]}"
    if [[ "$tok" == "-" || "$tok" == "--" || "$tok" != -* ]]; then
      first="$tok"; break
    fi
  done
  [[ -z "$first" ]]            && { echo FLAG; return; }        # bare/flags-only `git checkout`
  [[ "$first" == "--" ]]       && { echo SAFE; return; }        # pathspec restore
  [[ "$first" == "." ]]        && { echo SAFE; return; }        # cwd restore
  is_prevref "$first"          && { echo FLAG; return; }        # `-` / @{-N}
  is_headref "$first"          && { echo FLAG; return; }        # HEAD~N / HEAD@{N}
  is_sha "$first"              && { echo FLAG; return; }        # detached sha
  has_fileext "$first"         && { echo SAFE; return; }        # file restore (foo.txt)
  [[ -e "$first" ]]            && { echo SAFE; return; }        # existing path restore
  # bare branch name. MOVE carries the ref only for the plain one-operand form
  # (the canon lock's recovery exception); with options (`-f main`) it is FLAG.
  if [[ ${#a[@]} -eq 1 ]]; then echo "MOVE $first"; else echo FLAG; fi
}

# Classify the args of `git switch …`. There is no file-restore form of switch.
classify_switch() {
  local -a a=("$@") i tok branch=""
  for ((i = 0; i < ${#a[@]}; i++)); do
    tok="${a[i]}"
    if [[ "$tok" == "-c" || "$tok" == "-C" || "$tok" == "--create" ]]; then
      branch="${a[i + 1]-}"
      if [[ -n "$branch" ]] && is_solo "$branch"; then echo SAFE_CREATE; else echo FLAG; fi
      return
    fi
  done
  # any `git switch <branch>` / `-` / `--detach` / bare → FLAG; the plain
  # one-operand form carries its ref as MOVE (canon-lock recovery exception)
  if [[ ${#a[@]} -eq 1 && "${a[0]}" != -* ]] && ! is_prevref "${a[0]}"; then
    echo "MOVE ${a[0]}"
  else
    echo FLAG
  fi
}

# --- Canon lock (dotfiles#577 D1, ruling 11) -------------------------------
# The runtime canon clone: where ~/.claude/commands links into. Prints it, or
# returns 1 when there is no symlinked install (no runtime canon to lock).
canon_clone() {
  local c="${SST3_CANON_CLONE-}"
  if [[ -z "$c" ]]; then
    c="$(readlink -f "$HOME/.claude/commands" 2>/dev/null)" || return 1
    [[ "$c" == */.claude/commands && "$c" != "$HOME/.claude/commands" ]] || return 1
    c="${c%/.claude/commands}"
  fi
  printf '%s' "$c"
}
# resolve_dir <base> <dir> — expand ~ / $HOME, strip one layer of quotes,
# anchor a relative path at <base>.
resolve_dir() {
  local base="$1" d="$2"
  d="${d#\"}"; d="${d%\"}"; d="${d#\'}"; d="${d%\'}"
  case "$d" in
    '~')                 d="$HOME" ;;
    '~/'*)               d="$HOME/${d#\~/}" ;;
    '$HOME'|'${HOME}')   d="$HOME" ;;
    '$HOME/'*)           d="$HOME/${d#\$HOME/}" ;;
    '${HOME}/'*)         d="$HOME/${d#\$\{HOME\}/}" ;;
    /*)                  ;;
    *)                   d="$base/$d" ;;
  esac
  printf '%s' "$d"
}
# seg_cd_target <seg> — prints the target of a bare `cd X` / `pushd X` segment.
seg_cd_target() {
  local s="$1"
  while [[ "$s" == [[:space:]\(\{]* ]]; do s="${s#?}"; done
  if [[ "$s" =~ ^(cd|pushd)[[:space:]]*$ ]]; then printf '%s' "~"; return 0; fi
  [[ "$s" =~ ^(cd|pushd)[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]] || return 1
  [[ "${BASH_REMATCH[2]}" == "-" ]] && return 1
  printf '%s' "${BASH_REMATCH[2]}"
}
# seg_git_dirs <seg> <cwd> — the directories a git segment acts on: the cwd
# after every `-C` (chained, relative to the previous), plus any --work-tree /
# --git-dir / GIT_DIR / GIT_WORK_TREE value (a git dir maps to its parent).
seg_git_dirs() {
  local cur="$2" i v
  local -a w
  read -ra w <<<"$1" || true
  for ((i = 0; i < ${#w[@]}; i++)); do
    case "${w[i]}" in
      GIT_DIR=*)       v="${w[i]#GIT_DIR=}"; printf '%s\n' "$(resolve_dir "$cur" "${v%/.git}")" ;;
      GIT_WORK_TREE=*) printf '%s\n' "$(resolve_dir "$cur" "${w[i]#GIT_WORK_TREE=}")" ;;
      git|*/git)       break ;;
    esac
  done
  for ((i++; i < ${#w[@]}; i++)); do
    case "${w[i]}" in
      -C)             ((i++)); cur="$(resolve_dir "$cur" "${w[i]-}")" ;;
      -C?*)           cur="$(resolve_dir "$cur" "${w[i]#-C}")" ;;
      --work-tree)    ((i++)); printf '%s\n' "$(resolve_dir "$cur" "${w[i]-}")" ;;
      --work-tree=*)  printf '%s\n' "$(resolve_dir "$cur" "${w[i]#--work-tree=}")" ;;
      --git-dir)      ((i++)); v="${w[i]-}"; printf '%s\n' "$(resolve_dir "$cur" "${v%/.git}")" ;;
      --git-dir=*)    v="${w[i]#--git-dir=}"; printf '%s\n' "$(resolve_dir "$cur" "${v%/.git}")" ;;
      -c|--namespace) ((i++)) ;;
      -*)             ;;
      *)              break ;;
    esac
  done
  printf '%s\n' "$cur"
}
# in_canon <dir> — true when <dir> sits in the canon clone's MAIN working tree
# (a linked worktree under it has its own toplevel, so it is not locked). A directory the
# same command creates is not there yet: it is judged by its nearest existing parent, so a
# new folder inside the canon is in it (#577 Stage 5 fix review 2); a new linked worktree
# under the canon's .claude/worktrees/ is not.
in_canon() {
  local t d="$1"
  if [[ ! -d "$d" ]]; then
    [[ "$d" == "$CANON"/.claude/worktrees/* ]] && return 1
    while [[ -n "$d" && "$d" != / && ! -d "$d" ]]; do d="$(dirname -- "$d")"; done
  fi
  t="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$t" && "$t" -ef "$CANON" ]]
}
canon_deny() {
  local branch ahead
  branch="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$CANON" branch --show-current 2>/dev/null)"
  audit canon-deny "$1"
  printf 'SST3 branch-safety: BLOCKED — %s is the runtime canon clone: ~/.claude/commands, agents, skills, the checkbox MCP and every consumer ../dotfiles hook read its working tree, so a branch switch or create there silently swaps the canon every session runs (dotfiles#577 D1). It is on branch %s. Work in a worktree instead (EnterWorktree, or git worktree add under %s/.claude/worktrees/). The only move allowed here is the recovery: git checkout %s.\n' \
    "$CANON" "${branch:-<detached>}" "$CANON" "${CANON_DEFAULT:-<origin default branch: unresolved — run it yourself with the ! prefix>}" >&2
  exit 2
}

# Walk one shell segment. Echoes FLAG|SAFE|SKIP (SKIP = not a git command here).
classify_segment() {
  local seg="$1"
  # Fail-toward-FLAG (AC2 / Ralph Tier-3 #4): a git inline-alias that expands to
  # a branch verb (`git -c alias.co=checkout co …`, `git config alias.sw switch`)
  # IS a branch op the verb-walk cannot see (verb becomes the alias name).
  if [[ "$seg" =~ alias\.[A-Za-z0-9_-]+[[:space:]]*=?[[:space:]]*(checkout|switch)([^[:alnum:]_-]|$) ]]; then
    echo FLAG; return   # `alias.co=checkout`, `alias.x = checkout` (Stage-5 FN-3i: ws around `=`), `git config alias.sw switch`
  fi
  read -ra w <<<"$seg" || true
  local idx=0
  # Strip leading ENV=val assignments (GIT_DIR=… git checkout main → in-scope).
  while [[ "${w[idx]-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do ((idx++)); done
  # Unwrap leading shell grouping ( { ( ) and command-prefix wrappers so a real
  # `git checkout` reached THROUGH them resolves to its true verb instead of
  # being silently SAFE (Ralph Tier-3 #1; AC2 fail-toward-FLAG / dotfiles#488
  # backstopped verb set). `time git commit -m "…checkout…"` is unaffected:
  # after unwrapping `time`, the verb is correctly `commit` → SKIP.
  local _u=0 t
  while ((_u++ < 16)); do
    t="${w[idx]-}"
    [[ -z "$t" ]] && break
    if [[ "$t" == '('* || "$t" == '{'* ]]; then        # grouping, possibly glued (git {git
      while [[ "$t" == '('* || "$t" == '{'* ]]; do t="${t#?}"; done
      if [[ -z "$t" ]]; then ((idx++)); continue; fi    # standalone ( or {
      w[idx]="$t"; continue                             # re-evaluate stripped token
    fi
    # (backslash quote-removal is now handled generically in the pre-tokenisation
    # normalisation above — \git/g\it AND che\ckout/sw\itch — so no per-token
    # de-escape is needed here; Stage-5 Class-A FN fix.)
    # Leading `!` negation — `! git checkout main` still RUNS git checkout.
    if [[ "$t" == '!' ]]; then ((idx++)); continue; fi
    # Leading redirection prefix (`2>/dev/null git …`, `< f git …`, `>out git`,
    # `2>&1 git …`) precedes the command word; strip it so the real verb is
    # reached (Ralph Tier-3 #2). Bare operator → also consume its target token;
    # glued operator (target attached / fd-dup) → consume the one token.
    if [[ "$t" =~ ^([0-9]*(>>?|<>?|>&|<&)|&>>?) ]]; then
      if [[ "$t" =~ ^([0-9]*(>>?|<>?|>&|<&)|&>>?)$ ]]; then ((idx += 2)); else ((idx++)); fi
      continue
    fi
    case "$t" in
      time|command|nohup|exec|builtin|xargs|env|sudo|doas|nice|stdbuf)
        ((idx++))                                       # consume the wrapper word
        while :; do case "${w[idx]-}" in               # + its own opts / VAR=val
          -*|*=*) ((idx++)) ;; *) break ;; esac; done ;;
      *) break ;;
    esac
  done
  local g="${w[idx]-}"
  if [[ "$g" != "git" && "$g" != */git ]]; then
    # F2-b (Ralph Tier-3 #4): a parameter-expansion lead (`$GIT checkout …`,
    # `$a $b other` with a=git;b=checkout) could BE git — the value is opaque
    # to the classifier. If the segment carries a whole-word checkout/switch,
    # fail-toward-FLAG (AC2). Bounded: needs BOTH a `$`-lead AND a branch verb
    # word, so `$EDITOR notes.txt` / `VAR=x $GIT status` stay SAFE.
    if [[ "$g" == *'$'* && "$seg" =~ (^|[^[:alnum:]_-])(checkout|switch)([^[:alnum:]_-]|$) ]]; then
      echo FLAG; return
    fi
    # Couldn't resolve the lead to `git` after stripping every recognised
    # prefix. STRUCTURAL fail-toward-FLAG (AC2: never silently SAFE) — Ralph
    # Tier-3 proved 3× that an *enumerated* wrapper allow-list is the wrong
    # shape: any unmodelled exec-prefix (`timeout`/`setsid`/`ionice`/`chronic`/
    # `env -S '…'`/future) that runs `git checkout|switch` would leak. So:
    # if the raw segment carries a `git` … `checkout|switch` word sequence,
    # FLAG regardless of which prefix it was — no prior-wrapper precondition
    # (the earlier `unwrapped`-gate was removed as too narrow). NOTE: a
    # *resolved* `git commit -m "…checkout…"`
    # never reaches this branch (lead IS git → verb-classified as commit →
    # SKIP above). The accepted cost is a WARN-mode FLAG on exotic
    # consumer-of-the-literal forms (`echo git checkout`, `grep 'git switch'`)
    # — acceptable-by-design per AC2 fail-toward-FLAG + WARN-first (the
    # command still runs; the AC5 audit log makes it visible before the
    # operator gates DENY). `git`/`checkout` must each be whole shell-words
    # (so `git-checkout`, `gitcheckout`, `mygit checkout` do NOT match).
    if [[ "$seg" =~ (^|[^[:alnum:]_.-])git([^[:alnum:]_-].*)?[^[:alnum:]_-](checkout|switch)([^[:alnum:]_-]|$) ]]; then
      echo FLAG; return
    fi
    echo SKIP; return
  fi
  ((idx++))
  local gi=$idx                                                   # first token after `git`
  # Strip git global options so `git -C d checkout main` / `git -c k=v checkout`
  # resolve to the in-scope `checkout` verb (AC3a normalisation).
  while :; do
    case "${w[idx]-}" in
      -C|-c|--git-dir|--work-tree|--namespace) ((idx += 2)) ;;
      --git-dir=*|--work-tree=*|--namespace=*|-C?*|-c?*) ((idx++)) ;;
      -*) ((idx++)) ;;                                            # Stage-5 Class-B FN fix: ANY other git global option (--no-pager / -p / --paginate / --literal-pathspecs / --exec-path=… / --no-optional-locks / future). git requires every global option BEFORE the subcommand and a subcommand verb NEVER starts with '-', so a leading dash-token here is structurally a global option — strip it (structural, not an enumerated allow-list — the same shape the wrapper handling already adopted; the enumerated 5-entry list above silently SAFE'd `git --no-pager checkout main`, a verified HEAD-mover, before this).
      *) break ;;
    esac
  done
  # Fail-toward-FLAG (AC2): a quote in the pre-verb global-option region means
  # `read -ra` could not honour shell quoting and the verb resolution is
  # UNRELIABLE (e.g. `git -c 'user.name=x y' checkout main` splits the quoted
  # value and the parser loses the real `checkout` verb → would silently SAFE).
  # The git-`commit -m "…checkout…"` case is unaffected: its quote is AFTER the
  # verb (commit is reached with an empty global-opt region).
  local j
  for ((j = gi; j <= idx; j++)); do
    case "${w[j]-}" in *\'*|*\"*) echo FLAG; return ;; esac
  done
  local verb="${w[idx]-}"
  ((idx++))
  case "$verb" in
    worktree) echo SAFE ;;                                      # #488 CURE, verb-anchored
    checkout) classify_checkout "${w[@]:idx}" ;;
    switch)   classify_switch   "${w[@]:idx}" ;;
    *'$'*)    echo FLAG ;;                                       # F2-a: $-expanded git subcommand (`git $c other`) — unresolvable → fail-toward (AC2)
    *)        echo SKIP ;;                                       # status/add/push/… not in scope
  esac
}

# Fail-toward-FLAG trigger (AC2): a SKIP segment that textually carries a
# branch verb AND is led by a shell wrapper (eval / bash -c / sh -c) or
# contains command-substitution / backtick / here-string|heredoc — the verb
# is hidden from the parser, so never silently SAFE. A plain
# `git commit -m "…checkout…"` is led by `git` (verb commit), has no wrapper
# → NOT flagged (the substring is incidental, not a branch op).
seg_hides_branch_verb() {
  local s="$1"
  [[ "$s" == *checkout* || "$s" == *switch* ]] || return 1
  local -a ww
  read -ra ww <<<"$s" || true
  local j=0
  while [[ "${ww[j]-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do ((j++)); done
  local lead="${ww[j]-}"
  case "$lead" in eval|bash|sh|*/bash|*/sh) return 0 ;; esac
  [[ "$s" == *'$('* || "$s" == *'`'* || "$s" == *'<<'* ]] && return 0
  return 1
}

CANON="$(canon_clone)" || CANON=""
CANON_DEFAULT=""
if [[ -n "$CANON" ]]; then
  CANON_DEFAULT="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$CANON" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  CANON_DEFAULT="${CANON_DEFAULT#origin/}"
fi
CUR="$(printf '%s' "$raw_stdin" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -n "$CUR" ]] || CUR="$PWD"

# #577 Stage 5 fix review (R35/R36/R73): the canon lock reads the command with the shared shell
# reader _lib-shellcmd.py — quotes removed, sh -c / eval / $( ) unwrapped, and the directory each
# git runs in followed through cd/pushd in any spelling, subshells, env -C, git -C, --git-dir and
# an exported GIT_DIR. The segment loop below only knew a bare `cd X`, so `pushd X >/dev/null`,
# `cd -- X`, `--git-dir=X/.git/` and `sh -c '…'` reached the canon with a WARN. In the canon clone
# every checkout or switch is DENY except a `--` path restore (paths after the `--`; a bare
# trailing `--` only marks the branch) and the recovery to the default branch; so are
# `git bisect` (moves HEAD), `git symbolic-ref HEAD <ref>` and `gh pr checkout` / `gh co`.
# A command the reader cannot read whole (missing, failed, or an opaque part) is DENY here
# when the guard's directory is in the canon and the quote-stripped text names a branch verb
# (#577 Stage 5 fix review 2). The loop stays as a second reading.
canon_pass() {
  local lib out dir verdict unread=""
  lib="$(dirname "${BASH_SOURCE[0]}")/_lib-shellcmd.py"
  if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$lib" ]]; then
    unread="python3 or $lib missing"
  elif ! out="$(printf '%s' "$RAW_CMD" | python3 "$lib" git --cwd "$CUR" 2>/dev/null)"; then
    unread="the shell reader failed"
  else
    unread="$(printf '%s\n' "$out" | jq -r 'select(has("opaque")) | .opaque' 2>/dev/null | head -n 1)"
  fi
  if [[ -n "$unread" ]]; then
    audit canon-pass-unread "$unread"
    if in_canon "$CUR" && [[ "${RAW_CMD//[\'\"\\]/}" =~ (^|[^[:alnum:]_-])(checkout|switch|bisect|symbolic-ref|co)([^[:alnum:]_-]|$) ]]; then
      canon_deny "$RAW_CMD"
    fi
    [[ -n "${out:-}" ]] || return 0
  fi
  [[ -n "$out" ]] || return 0
  out="$(printf '%s\n' "$out" | jq -r --arg def "$CANON_DEFAULT" '
    select(has("verb"))
    | (if .git_dir then (if (.git_dir | endswith("/.git")) then (.git_dir | rtrimstr("/.git")) else .git_dir end)
     else .cwd end) as $d
    | ($d // "") + "\t" + (
        if .tool == "gh" then "deny"
        elif .verb == "checkout" then
          (if (.args | length) == 0 or ((.args | index("--")) as $k | $k != null and $k < (.args | length) - 1)
              or ($def != "" and .args == [$def]) then "ok" else "deny" end)
        elif .verb == "symbolic-ref" then
          (if any(.args[]; IN("-d", "--delete")) or ([.args[] | select(startswith("-") | not)] | length) >= 2
           then "deny" else "ok" end)
        elif .verb == "switch" then
          (if (.args | length) == 0 or ($def != "" and .args == [$def]) then "ok" else "deny" end)
        elif .verb == "bisect" then
          (if (.args | length) == 0 or (.args[0] | IN("log", "visualize", "view", "terms", "help")) then "ok" else "deny" end)
        else "ok" end)' 2>/dev/null)" || { audit canon-pass-not-run "jq could not read the reader output"; return 0; }
  while IFS=$'\t' read -r dir verdict; do
    [[ "$verdict" == deny && -n "$dir" ]] || continue
    in_canon "$dir" && canon_deny "$RAW_CMD"
  done <<<"$out"
  return 0
}
[[ -n "$CANON" ]] && canon_pass

# Split the whole command on shell control operators, scan every segment.
# Every segment is scanned before the WARN fires, so a canon-clone segment
# after an ordinary flagged one is still DENIED (flag() exits on the first).
NORM="${CMD//&&/$'\n'}"; NORM="${NORM//||/$'\n'}"
NORM="${NORM//;/$'\n'}"; NORM="${NORM//|/$'\n'}"
want_flag=0
while IFS= read -r seg; do
  [[ -z "${seg// /}" ]] && continue
  if cdt="$(seg_cd_target "$seg")"; then CUR="$(resolve_dir "$CUR" "$cdt")"; continue; fi
  verdict="$(classify_segment "$seg")"
  case "$verdict" in
    SAFE) continue ;;                                            # file restore / worktree verb
    SKIP) seg_hides_branch_verb "$seg" || continue; verdict=FLAG ;;  # wrapper hiding a verb → fire
  esac
  # verdict ∈ FLAG | SAFE_CREATE | MOVE <ref>
  if [[ -n "$CANON" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] && in_canon "$d" || continue
      [[ -n "$CANON_DEFAULT" && "$verdict" == "MOVE $CANON_DEFAULT" ]] && continue 2   # the recovery
      canon_deny "$CMD"
    done < <(seg_git_dirs "$seg" "$CUR")
  fi
  [[ "$verdict" == SAFE_CREATE ]] && continue                    # solo/ create outside the canon clone
  want_flag=1                                                    # parsed git branch op → fire
done <<<"$NORM"

[[ $want_flag -eq 1 ]] && flag "$CMD"
safe
