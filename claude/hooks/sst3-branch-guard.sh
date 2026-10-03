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
# SAFE in the segment walk below.)
if [[ "$CMD" != *checkout* && "$CMD" != *switch* ]]; then
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
      if [[ -n "$branch" ]] && is_solo "$branch"; then echo SAFE; else echo FLAG; fi
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
  echo FLAG                                                     # bare branch name
}

# Classify the args of `git switch …`. There is no file-restore form of switch.
classify_switch() {
  local -a a=("$@") i tok branch=""
  for ((i = 0; i < ${#a[@]}; i++)); do
    tok="${a[i]}"
    if [[ "$tok" == "-c" || "$tok" == "-C" || "$tok" == "--create" ]]; then
      branch="${a[i + 1]-}"
      if [[ -n "$branch" ]] && is_solo "$branch"; then echo SAFE; else echo FLAG; fi
      return
    fi
  done
  echo FLAG   # any `git switch <branch>` / `-` / `--detach` / bare → FLAG
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

# Split the whole command on shell control operators, scan every segment.
NORM="${CMD//&&/$'\n'}"; NORM="${NORM//||/$'\n'}"
NORM="${NORM//;/$'\n'}"; NORM="${NORM//|/$'\n'}"
while IFS= read -r seg; do
  [[ -z "${seg// /}" ]] && continue
  verdict="$(classify_segment "$seg")"
  case "$verdict" in
    FLAG) flag "$CMD" ;;                                         # parsed git branch op → fire
    SKIP) seg_hides_branch_verb "$seg" && flag "$CMD" ;;          # wrapper hiding a verb → fire
  esac
done <<<"$NORM"

safe
