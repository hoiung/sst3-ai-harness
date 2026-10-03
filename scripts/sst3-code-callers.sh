#!/usr/bin/env bash
# sst3-code-callers.sh — Reverse-call lookup for a symbol via ast-grep fallback.
#
# Usage:   sst3-code-callers.sh <symbol> <lang>
# Example: sst3-code-callers.sh BANNED_WORDS python
# Output:  NDJSON, one object per call site: {file, line, kind}
#          line is a 1-indexed editor line (#547 AC 7.1).
# Design:  Primary engine intended is the CC `LSP` tool's `incomingCalls`,
#          callable by an agent directly when LSP is wired for the language.
#          When LSP is not wired (verified Phase 1 smoke 2026-04-25), this
#          bash wrapper falls back to ast-grep call-site pattern matching.
#          Missing ast-grep → stderr contract + exit 127.

set -euo pipefail
export LC_ALL=C


SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-code-callers" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-code-callers" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"

# --paths-from retrofit (#447 Phase 8): strip --paths-from from positional args
# and (if a filter NDJSON was supplied) install a transparent stdout filter
# via activate_paths_from_filter from sst3-bash-utils.sh.
__PATHS_FROM_SST3=""
__ARGS_SST3=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths-from) __PATHS_FROM_SST3="${2:-}"; shift 2 || break;;
        *) __ARGS_SST3+=("$1"); shift;;
    esac
done
set -- "${__ARGS_SST3[@]+"${__ARGS_SST3[@]}"}"
activate_paths_from_filter "$__PATHS_FROM_SST3"

if [[ $# -lt 2 ]]; then
    echo "ERROR: usage: $(basename "$0") <symbol> <lang>" >&2
    exit 64
fi

SYMBOL="$1"
RAW_LANG="$2"

assert_safe_identifier "$SYMBOL"
LANG=$(normalise_lang "$RAW_LANG")

if ! command -v ast-grep >/dev/null 2>&1; then
    echo 'ERROR: ast-grep not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

# Recall requires TWO complementary call-site shapes (#496), plus a third for
# JS/TS constructors and a command shape for bash (#577, below). ast-grep matches structurally, so a single
# pattern cannot cover both:
#   1. free-function / associated call:  SYMBOL(...)       — identifier callee
#   2. method / receiver call:           RECV.SYMBOL(...)  — field-expression callee
# Pre-#496 only shape 1 ran, so method calls (Rust `redis.write_ohlcv(...)`,
# Python `obj.method(...)`, JS `this.method(...)`) were a 100% recall miss.
# The two shapes are structurally DISJOINT (a call's callee is either an
# identifier or a field-expression, never both), so no call is matched by both
# patterns and their outputs are simply concatenated with NO dedup step. Dedup
# would be WRONG here: two distinct same-symbol calls on one physical line
# render an identical {file,line,kind} record, and both must be preserved (as
# the single pre-#496 pattern did) — collapsing them would silently drop a real
# call site (recall regression). ast-grep also emits each match once per
# pattern, so no intra-pattern duplication exists to collapse.
#
# KNOWN LIMITATION (#496): neither shape matches a call INSIDE a macro body
# (Rust `assert!(SYMBOL(...))`, `assert_eq!(...)`) — tree-sitter represents
# macro arguments as an opaque token-tree, not parsed expressions, so ast-grep
# cannot descend into them. This is an inner-engine (tree-sitter) constraint,
# not a pattern gap; the Leader.md raw-grep counter-query gate is the
# compensating control for macro-heavy / test-assertion call sites.
emit_call_sites() {
    # $1 = an `ast-grep run` pattern; with $2 = rule, an inline YAML rule for
    # `ast-grep scan` instead (the bash shape below needs a node kind).
    # #547 AC 6.1: buffer-then-check — the rc gate runs BEFORE jq sees the
    # stream (broken-engine garbage cannot crash jq or leak bare stderr).
    local ag_out ag_rc=0
    ag_out=$(mktemp)
    if [[ "${2:-}" == rule ]]; then
        ast-grep scan --inline-rules "$1" --json=stream > "$ag_out" 2>/dev/null || ag_rc=$?
    else
        ast-grep run --pattern "$1" --lang "$LANG" --json=stream > "$ag_out" 2>/dev/null || ag_rc=$?
    fi
    ast_grep_check_rc "sst3-code-callers" "$ag_rc" || { rm -f "$ag_out"; exit 0; }
    jq -c '{file, line: (.range.start.line + 1), kind: "call"}' < "$ag_out"  # #547 AC 7.1: 1-indexed
    rm -f "$ag_out"
}
# Bash: a call is a command, `fn args` with no parentheses, so none of the
# shapes below matches one: the wrapper answered 0 sites for every bash
# function (#577 Gate 1: 19 real calls of `run_or_skip`). A command's name node
# is the call; a definition's name, an argument and a comment are not. SYMBOL
# has passed assert_safe_identifier, so with `.` escaped it is literal in the regex.
if [[ "$LANG" == bash ]]; then
    emit_call_sites "$(printf 'id: sst3-call\nlanguage: bash\nseverity: hint\nrule:\n  kind: command_name\n  regex: ^%s$\n' "${SYMBOL//./\\.}")" rule
    exit 0
fi
emit_call_sites "${SYMBOL}(\$\$\$)"
emit_call_sites "\$SST3_RECV.${SYMBOL}(\$\$\$)"
# 3. JS/TS constructor call:  new SYMBOL(...) — a new_expression, not a
#    call_expression, so neither shape above matches it (#577 AC 2.5: a
#    TypeScript class with 22 references returned 0 sites). Disjoint from both
#    shapes above, so it too is concatenated without dedup.
case "$LANG" in
    javascript|typescript|tsx) emit_call_sites "new ${SYMBOL}(\$\$\$)" ;;
esac
