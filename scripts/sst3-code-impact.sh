#!/usr/bin/env bash
# sst3-code-impact.sh — Blast-radius analysis for files changed vs a base branch.
#
# Usage:   sst3-code-impact.sh <base-branch>
# Example: sst3-code-impact.sh main
# Output:  NDJSON, one object per changed file: {changed_file, impacted_callers}
#          where impacted_callers is an integer count of call sites referencing
#          a named function/method defined in changed_file (kind-rule
#          extraction — class/impl methods included; #546).
# Engines: git diff --name-only base...HEAD; ast-grep --json=stream — per-file
#          definition extraction + ONE repo-wide caller-name index per language.

set -euo pipefail
export LC_ALL=C


SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-code-impact" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-code-impact" "${SST3_EMITTED_COUNT:-0}"
    fi
    exit 143
}
trap on_sigterm SIGTERM

# shellcheck source=./sst3-bash-utils.sh
source "$(dirname "$0")/sst3-bash-utils.sh"

# NO wrapper_sentinel EXIT trap here, deliberately (Stage-5 #546, fixture-
# proven): sst3-code-review.sh composes this wrapper via `$(... 2>&1)`,
# so ANY stderr line would land inside IMPACT_OUT and break its jq parse
# (code-review-untested-error fixture exit 5). SST3_EMITTED_COUNT still
# increments per record so on_sigterm's partial_records field is accurate.

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

if [[ $# -lt 1 ]]; then
    echo "ERROR: usage: $(basename "$0") <base-branch>" >&2
    exit 64
fi

BASE="$1"

if ! command -v ast-grep >/dev/null 2>&1; then
    echo 'ERROR: ast-grep not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

# git prints the changed names relative to the top of the work tree and the
# caller index walks the cwd, so from a subdirectory every name failed the `-f`
# test below and the run said nothing (#577 Stage 5 fix review R7). Work from
# the top; outside a work tree the diff below fails and says so.
if _sst3_top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    cd -- "$_sst3_top"
fi

# #577 Stage 5 S14: the list ran through `2>/dev/null || true`, so a bad base was an
# empty list and exit 0 with nothing said (nothing here validates the base); without
# -z a quoted name was handed to ast-grep as `"caf\303\251.py"` and missed.
if ! CHANGED="$(probe_names_or_fail "sst3-code-impact: changed files" -- \
        git diff --name-only -z "${BASE}...HEAD" -- '*.py' '*.ts' '*.tsx' '*.js' '*.jsx' '*.rs')"; then
    exit 2
fi

if [[ -z "$CHANGED" ]]; then
    exit 0
fi

# #546 Phase 4 (operator-reported crawl): the previous per-symbol repo-wide
# scan helper made the composed sst3-code-review.sh appear to
# HANG on real repos — each scan cost ~0.3s wall / ~3s CPU on a 1000-file
# repo, and a 34-file diff demanded ~800 of them (bare + `$SST3_RECV.` +
# rust `$SST3_PATH::` / ts-js `$SST3_RECV?.` shapes per symbol). Standalone
# the records stream progressively so it looks fine; nested inside
# review.sh's command substitution NOTHING appears until every scan
# finishes — the reported 5+min zero-output "pipe hang" (bash reader at ~0
# CPU while ast-grep children grind invisibly).
# Ported fix = sst3-code-orphans.sh (its #544 Stage-5 D1 batch
# index): ONE `$NAME($$$)` pass per changed-set language binds the FULL
# callee node for EVERY call shape — identifier (`f()`), field-expression
# (`obj.f()` / `this.f()`), scoped_identifier path (`crate::lib::f()`),
# optional-chain (`w?.f()`). Normalizing the callee text (`?`→``, `::`→`.`)
# and keying by the last dotted component merges the shapes into per-name
# totals, preserving the #496/#544/#546 recall exactly (the three impact
# fixtures lock the counts: rust 4, ts 3, python 3/0). Same-name symbols on
# different classes/modules merge — safe over-count for an impact advisory,
# the same documented orphans.sh trade-off. Cost: ≤5 index passes (one per
# supported language, ~1-3s each on a 1000-file repo) instead of ~800 scans
# (~minutes). Stage-5 (#546) follow-through: counts preload into an
# in-process assoc array — the initial per-symbol awk lookup forked one
# subprocess per symbol (measured 5-10s across a 1000-symbol diff, ~half the
# wrapper's wall time); lookups are now fork-free (index shape still the
# orphans.sh #544 D1 batch-index port, lookup upgraded from its awk scan).
declare -A CALLER_CNT INDEX_BUILT
# #547 AC 5.4 (CX): typescript/tsx/javascript share ONE `jsfam` index bucket,
# built from all three language scans on first encounter — a `.ts` def called
# from `.tsx`/`.js` now counts (probe-confirmed false negative under the old
# per-$LANG buckets). Same-name merges stay the accepted safe over-count.
lang_family() {
    case "$1" in
        typescript|tsx|javascript) echo "jsfam" ;;
        *) echo "$1" ;;
    esac
}
build_caller_index() {
    local fam="$1" lang n c langs
    case "$fam" in
        jsfam) langs="typescript tsx javascript" ;;
        *) langs="$fam" ;;
    esac
    for lang in $langs; do
        # #547 AC 6.1: buffer-then-check — the rc gate runs BEFORE jq sees the
        # stream (rc 1 = zero-matches stays benign; rc >= 2 = broken engine →
        # -error record + exit 0). pipefail stays off in the filter chain only
        # for grep-on-empty-input.
        local ag_tmp ag_rc
        ag_tmp=$(mktemp)
        ag_rc=0
        # shellcheck disable=SC2016  # $NAME is an ast-grep meta-var, not shell
        ast-grep run --pattern '$NAME($$$)' --lang "$lang" --json=stream > "$ag_tmp" 2>/dev/null || ag_rc=$?
        ast_grep_check_rc "sst3-code-impact" "$ag_rc" || { rm -f "$ag_tmp"; exit 0; }
        while IFS=$'\t' read -r n c; do
            CALLER_CNT["$fam:$n"]=$(( ${CALLER_CNT["$fam:$n"]:-0} + c ))
        done < <( set +o pipefail
          jq -r '.metaVariables.single.NAME.text // empty' < "$ag_tmp" \
            | awk '{ gsub(/\?/,""); gsub(/::/,"."); n=split($0,a,"."); print a[n] }' \
            | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*$' \
            | sort | uniq -c | awk '{print $2"\t"$1}' )
        rm -f "$ag_tmp"
    done
    INDEX_BUILT[$fam]=1
}

while IFS= read -r FILE; do
    [[ -f "$FILE" ]] || continue
    # Language dispatch (AC 5.1 dotfiles#516 kept the per-language split; #546
    # ports the extraction itself from shape patterns to kind-rules).
    # #548: `.jsx` dispatches to `javascript`, NOT `tsx`. Probe-confirmed on
    # ast-grep 0.42.1: the tsx grammar yields ZERO matches on a .jsx file
    # (explicit-file and repo-wide walk alike), so a `tsx` dispatch would admit
    # the file and then extract no symbols — emitting a confident
    # `impacted_callers: 0` false clean, strictly worse than the pre-#548
    # omission it replaced. The javascript grammar parses and discovers .jsx.
    # Locked by test-fixtures/code-impact-jsx-recall (asserts a NON-ZERO count).
    case "$FILE" in
        *.py)  LANG="python" ;;
        *.ts)  LANG="typescript" ;;
        *.tsx) LANG="tsx" ;;
        *.js)  LANG="javascript" ;;
        *.jsx) LANG="javascript" ;;
        *.rs)  LANG="rust" ;;
        *)     continue ;;
    esac
    # #546: definition extraction ported to the #445 R4 kind-rule convention
    # already used by sst3-code-callees.sh:98-155 and sst3-code-large.sh.
    # Shape patterns cannot match nodes carrying extra children, so Rust
    # `pub`/`pub(crate)`/`pub async` fns and impl methods (visibility_modifier
    # child), JS/TS class methods (method_definition kind), and typed/exported
    # functions were never extracted — measured recall on the #546 probe tree:
    # rust 2/6, ts 1/6 (python 3/3). Kind-rules recover 6/6 / 6/6 / 3/3.
    # Anonymous arrows have no `name` field and stay unaddressable by name
    # (same limit as callees.sh:119-120). variable_declarator also yields
    # non-function consts and destructuring patterns — non-identifier names
    # are filtered below; over-extraction adds mostly-0-count lookups (a
    # const name colliding with a called function elsewhere can add a small
    # over-count — the same coarse-name imprecision this advisory already
    # carries; over-count errs safe).
    # shellcheck disable=SC2016  # $NAME inside rule strings is an ast-grep meta-var, not a shell expansion
    case "$LANG" in
        python)
            EXTRACT_RULE='id: impact-defs
language: python
rule:
  kind: function_definition
  has:
    field: name
    pattern: $NAME' ;;
        typescript|tsx|javascript)
            EXTRACT_RULE="id: impact-defs
language: $LANG
rule:
  any:
    - kind: function_declaration
    - kind: method_definition
    - kind: variable_declarator
  has:
    field: name
    pattern: \$NAME" ;;
        rust)
            EXTRACT_RULE='id: impact-defs
language: rust
rule:
  kind: function_item
  has:
    field: name
    pattern: $NAME' ;;
    esac
    # pipefail disabled in this subshell only: zero matches make ast-grep exit
    # non-zero (as does grep on empty input), which would otherwise abort the
    # loop under set -o pipefail. The grep keeps only plain ASCII identifiers:
    # destructuring declarators bind the whole pattern text (`{a, b}`) as
    # $NAME, and assert_safe_identifier below exit-64s on those — drop them
    # here instead (orphans.sh emit-site precedent). Deliberate trade-off (Ralph
    # Tier-2/3 #546): JS/TS `$`-identifiers (`data$`, `$emit`) and non-ASCII
    # identifiers (`def café()`) are ALSO dropped silently and their call
    # sites uncounted — assert_safe_identifier rejects both classes, so
    # pre-#546 the same symbols exit-64'd the WHOLE run; silent-drop is the
    # milder failure mode, and the raw counter-query lane (playbook #484
    # W6.4) is the recall backstop.
    # #547 AC 6.1: buffer-then-check per changed file (same gate as the index).
    AG_TMP=$(mktemp)
    AG_RC=0
    ast-grep scan --inline-rules "$EXTRACT_RULE" --json=stream "$FILE" > "$AG_TMP" 2>/dev/null || AG_RC=$?
    ast_grep_check_rc "sst3-code-impact" "$AG_RC" || { rm -f "$AG_TMP"; exit 0; }
    SYMBOLS=$( set +o pipefail
        jq -r '.metaVariables.single.NAME.text // empty' < "$AG_TMP" \
            | grep -E '^[a-zA-Z_][a-zA-Z0-9_]*$' \
            | sort -u )
    rm -f "$AG_TMP"
    FAM=$(lang_family "$LANG")
    [[ -z "${INDEX_BUILT[$FAM]:-}" ]] && build_caller_index "$FAM"
    COUNT=0
    for SYM in $SYMBOLS; do
        [[ -z "$SYM" ]] && continue
        assert_safe_identifier "$SYM"
        # Per-symbol count = one fork-free assoc lookup. The index already
        # merged every call shape (#496/#544 bare+receiver, #546 scoped +
        # optional-chain) by last-component key — see the Phase-4 block above.
        COUNT=$((COUNT + ${CALLER_CNT[$FAM:$SYM]:-0}))
    done
    jq -nc --arg f "$FILE" --argjson c "$COUNT" '{changed_file: $f, impacted_callers: $c}'
    SST3_EMITTED_COUNT=$((SST3_EMITTED_COUNT + 1))
done <<< "$CHANGED"
