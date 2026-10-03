#!/usr/bin/env bash
# sst3-code-review.sh — Composite diff-scoped review (replaces 4MB-JSON monolith).
#
# Usage:   sst3-code-review.sh <base-ref>
# Example: sst3-code-review.sh origin/main   (a fetched remote ref — a stale local
#          branch ref silently widens the BASE...HEAD diff)
# Output:  path to a per-invocation NDJSON file echoed on stdout; default
#          `mktemp -t sst3_review.XXXXXX.ndjson`, override via SST3_REVIEW_NDJSON.
#          The file chains:
#            {section:"impact", changed_file, impacted_callers}
#            {section:"untested-in-diff", file, untested:[names]}
#            {section:"untested-in-diff", status:"skipped", reason}  (#548 — coverage
#              precondition unmet; a DIFFERENT field set from the record above,
#              carrying no `.file`/`.untested`. Consumers selecting this section
#              must branch on `.status`, the same way the two review-error
#              variants below share only section+source.)
#            {section:"empty-diff-range", base, note}  (BASE...HEAD has 0 changed files; exit 0 no-op)
#            {section:"empty-impact-scope", base, note} (changed files exist, none impact-scoped; #547 AC 6.2b)
#            {section:"review-error", source, exit, stderr}            (engine exited non-zero; #447 Phase 3)
#            {section:"review-error", source, kind, reason, detail}    (untested-py exit-0 error record passed through; #544)
#            {section:"review-error", source, kind, reason, rc}        (impact-leg *-error record rerouted by endswith; #547 AC 6.2a)
# Engines: composes sst3-code-impact.sh + sst3-code-untested-py.sh.

set -euo pipefail
export LC_ALL=C


SST3_EMITTED_COUNT="${SST3_EMITTED_COUNT:-0}"
on_sigterm() {
    if command -v jq >/dev/null 2>&1; then
        jq -nc --arg n "sst3-code-review" --argjson e "${SST3_EMITTED_COUNT:-0}" \
            '{kind:($n + "-killed"), reason:"sigterm", partial_records:$e}'
    else
        printf '{"kind":"%s-killed","reason":"sigterm","partial_records":%s}\n' \
            "sst3-code-review" "${SST3_EMITTED_COUNT:-0}"
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

if [[ $# -lt 1 ]]; then
    echo "ERROR: usage: $(basename "$0") <base-branch>" >&2
    exit 64
fi

# #447 Phase 3 (Shape 27): startup engine checks. Previously code-review.sh had
# zero — relied on inner wrappers exiting 127. The blanket `|| true` patterns
# below then conflated engine-missing with empty-result, hiding the diagnostic.
if ! command -v ast-grep >/dev/null 2>&1; then
    echo 'ERROR: ast-grep not installed (required by sst3-code-impact.sh); see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
    echo 'ERROR: jq not installed; see dotfiles/docs/guides/code-query-playbook.md "Wrapper-Script Lane > Install"' >&2
    exit 127
fi

BASE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# #447 Phase 3 (Shape 7): fixed `/tmp/review.ndjson` raced multi-shell. Default
# to mktemp; SST3_REVIEW_NDJSON overrides (test fixtures + deterministic dev).
OUT="${SST3_REVIEW_NDJSON:-$(mktemp -t sst3_review.XXXXXX.ndjson)}"

: > "$OUT"

# #520 (item-3): a bad/typo'd base ref must NOT be silently swallowed by the
# empty-range guard below (`git rev-list ... 2>/dev/null || echo 0` would map an
# unresolvable ref to RANGE_COUNT=0 and report "nothing to review" — reintroducing
# the very silent-failure class this guard fixes: a typo'd ref looking like a clean
# diff). Validate the ref FIRST and fail loud with the reserved usage code 64.
if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1; then
    echo "ERROR: base ref '${BASE}' does not resolve to a commit" >&2
    exit 64
fi

# #520 (item-3): empty-diff-range guard. When BASE...HEAD has no changed files
# (e.g. the Stage-5 audit running `review.sh <default>` AFTER a merge, so the
# range is empty), the impact engine emits 0 bytes rc 0 and the `grep -v '^$'`
# pipe below exits 1 — under `pipefail`+`set -e` that aborts the script BEFORE
# `echo "$OUT"`, a silent exit 1 indistinguishable from "engine broken". An empty
# range is a legitimate no-op: emit a distinct diagnostic and exit 0. Exit codes
# 64/127/143 stay reserved for usage / engine-missing / sigterm.
#
# #520 Stage-5 fix: guard on the SAME `git diff --name-only "${BASE}...HEAD"` the
# engines consume (impact: sst3-code-impact.sh:57; untested-py CHANGED: line 119
# below — both 3-dot = merge-base..HEAD, HEAD-side changes only), NOT a
# `git rev-list --count` commit proxy. rev-list with a 3-dot range counts the
# SYMMETRIC commit difference (commits unique to EITHER side), so when BASE is a
# descendant of / diverged-ahead-of HEAD (e.g. local HEAD lags origin/master and
# origin/master is passed as base) the proxy sees commits while the diff is empty:
# the engines emit nothing and the script writes an empty $OUT and exits 0
# silently — the very silent-empty class this guard kills, escaping through a
# divergent base. Counting changed files off the engine's own range is
# definitionally aligned. BASE is ref-validated above, so an empty list here is a
# genuine empty range, not a bad ref.
CHANGED_FILES=$(git diff --name-only "${BASE}...HEAD" 2>/dev/null || true)
if [[ -z "$CHANGED_FILES" ]]; then
    EMPTY_NOTE="no changed files in ${BASE}...HEAD; nothing to review"
    jq -nc --arg b "$BASE" --arg note "$EMPTY_NOTE" \
        '{section:"empty-diff-range", base:$b, note:$note}' >> "$OUT"
    echo "empty-diff-range: $EMPTY_NOTE" >&2
    echo "$OUT"
    exit 0
fi

# #447 Phase 3 (Shape 27): replaced blanket `|| true` with explicit per-step
# error capture. If sst3-code-impact.sh fails (engine-broken / SIGTERM), we
# emit a structured diagnostic instead of silently producing an empty review.
set +e
IMPACT_OUT=$(bash "$SCRIPT_DIR/sst3-code-impact.sh" "$BASE" 2>&1)
IMPACT_RC=$?
set -e
if [[ $IMPACT_RC -ne 0 ]]; then
    jq -nc --arg s "$IMPACT_OUT" --argjson rc "$IMPACT_RC" \
        '{section:"review-error", source:"sst3-code-impact", exit:$rc, stderr:$s}' >> "$OUT"
elif [[ -z "$(printf '%s' "$IMPACT_OUT" | tr -d '[:space:]')" ]]; then
    # #547 AC 6.2(b): the outer diff is non-empty but the impact leg produced
    # ZERO records (all changed files outside impact's 6-ext filter; #548 added
    # jsx to it) — append
    # the symmetric record; the empty-diff-range record above covers only the
    # empty-outer-diff case.
    jq -nc --arg b "$BASE" \
        '{section:"empty-impact-scope", base:$b,
          note:"changed files exist but none match the impact extension filter (py/ts/tsx/js/jsx/rs)"}' >> "$OUT"
    echo "empty-impact-scope: no impact-scoped files in ${BASE}...HEAD" >&2
else
    # #520 (item-3): `grep -v` exits 1 on empty-but-successful impact output;
    # under pipefail+set -e that aborts the script. No-match is NOT an error
    # here (rc 0 + empty is a valid "nothing impacted") — guard with `|| true`.
    # #547 AC 6.2(a): impact exits 0 while carrying {kind:"<wrapper>-error"}
    # records (#544 convention via ast_grep_check_rc — broken engine). Route
    # any kind ending in "-error" to section:"review-error" keeping its own
    # fields — endswith (unlike the untested-py leg's exact match) covers every
    # wrapper's error kind arriving through the impact composition.
    printf '%s\n' "$IMPACT_OUT" | { grep -v '^$' || true; } \
        | jq -c '
            if ((.kind // "") | endswith("-error")) then
                . + {section: "review-error", source: "sst3-code-impact"}
            else
                . + {section: "impact"}
            end
          ' >> "$OUT"
fi

# #548: the coverage gate used to fall through in SILENCE — in a worktree with
# no `.coverage` (the common case; worktrees start without one) the
# untested-in-diff section emitted zero records, and 0 records is
# indistinguishable from analysed-and-clean. Fail-loud doctrine (AP #27 shape):
# emit an explicit skip record naming WHICH precondition failed.
#
# The changed-Python check is the OUTER gate, deliberately. A skip record must
# mean "there was Python to analyse and I could not", never "there was no
# Python". Gating the skip on the coverage precondition alone (the first cut of
# this fix, caught by Ralph Tier 2) fired the record on every non-Python diff in
# a fresh worktree — near-universal noise that would have re-buried the very
# signal this change exists to surface. The if/else restructure also removes a
# duplicate evaluation — of the COVERAGE PRECONDITION, which the intermediate
# cut tested twice (once to emit the skip, once to guard the real path).
# `$CHANGED` itself was only ever evaluated once.
CHANGED=$(git diff --name-only "${BASE}...HEAD" -- '*.py' 2>/dev/null || true)
if [[ -n "$CHANGED" ]]; then
    if [[ ! -f .coverage ]] || ! command -v coverage >/dev/null 2>&1; then
        if [[ ! -f .coverage ]]; then
            SKIP_REASON="no .coverage data file in $(pwd)"
        else
            SKIP_REASON="coverage tool not on PATH"
        fi
        jq -nc --arg r "$SKIP_REASON" \
            '{section:"untested-in-diff", status:"skipped", reason:$r}' >> "$OUT"
    else
        set +e
        UNTESTED_OUT=$(bash "$SCRIPT_DIR/sst3-code-untested-py.sh" 2>&1)
        UNTESTED_RC=$?
        set -e
        if [[ $UNTESTED_RC -ne 0 ]]; then
            jq -nc --arg s "$UNTESTED_OUT" --argjson rc "$UNTESTED_RC" \
                '{section:"review-error", source:"sst3-code-untested-py", exit:$rc, stderr:$s}' >> "$OUT"
        else
            # #520 (item-3): same guard — untested-py returns empty rc 0 when all
            # changed .py are tested; no-match `grep -v` exit 1 must not abort.
            # #544: untested-py deliberately exits 0 with a structured
            # {kind:"untested-py-error"} record on unusable coverage data
            # (#445 R4 Bug E contract — cross-host paths / corrupt data file).
            # That record has no `.file`, so the file-membership select below
            # silently dropped it and the review read as "all changed Python
            # covered". Route error records through as review-error, keeping
            # the record's own {kind, reason, detail} fields — a DIFFERENT
            # field set from the rc!=0 branch above ({exit, stderr}); the two
            # review-error variants share only section+source (see header).
            printf '%s\n' "$UNTESTED_OUT" | { grep -v '^$' || true; } \
                | jq -c --arg changed "$CHANGED" '
                    . as $u |
                    ($changed | split("\n")) as $files |
                    if ($u.kind // "") == "untested-py-error" then
                        $u + {section: "review-error", source: "sst3-code-untested-py"}
                    else
                        ( select($u.file as $f | $files | index($f)) |
                          $u + {section: "untested-in-diff"} )
                    end
                  ' >> "$OUT"
        fi
    fi
fi

echo "$OUT"
